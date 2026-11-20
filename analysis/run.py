"""Run the scientific analysis sequentially using a local SAS installation."""
from __future__ import annotations
import argparse,csv,hashlib,json,os,re,subprocess,sys,uuid,time
from pathlib import Path
PACKAGE=Path(__file__).resolve().parent
sys.path.insert(0,str(PACKAGE/'python'))
from file_utils import digest,write_once,safe_path

class AnalysisError(ValueError):pass

def require(ok,message):
    if not ok:raise AnalysisError(message)

def read_json(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def file_hash(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def package_hash():
    """Bind scientific sources and settings, excluding local dependency environments."""
    entry_files={'run.py','validate.py','convert_results.py','run.sas'}
    specification_files={'scientific_settings.json','models.csv','weekday_settings.json','weekday_models.csv','requirements.txt'}
    root_executables={p.name for p in PACKAGE.iterdir()
                      if p.is_file() and p.suffix.lower() in {'.py','.sas'}}
    require(root_executables <= entry_files,
            'Unexpected executable at package root: '+', '.join(sorted(root_executables-entry_files)))
    files={PACKAGE/name for name in entry_files | specification_files}
    require(all(p.is_file() for p in files),'A required scientific source or specification file is missing.')
    for name,suffix in (('python','.py'),('sas','.sas')):
        directory=PACKAGE/name
        require(directory.is_dir(),'A scientific source directory is missing: '+name)
        files.update(p for p in directory.rglob('*')
                     if p.is_file() and p.suffix.lower()==suffix
                     and '__pycache__' not in p.relative_to(directory).parts)
    files.update(p for p in (PACKAGE/'results').rglob('*') if p.is_file() and p.suffix.lower() in {'.py','.json'} and '__pycache__' not in p.parts)
    return digest({p.relative_to(PACKAGE).as_posix():file_hash(safe_path(p)) for p in sorted(files)})

def configuration(path):
    c=read_json(path)
    required={'sas_executable','sas_config_file','input_directory','output_directory','measurements_member','transfusions_member','admissions_member','input_version','cohort_mode'}
    require(set(c)==required,'Configuration must contain exactly the documented fields.')
    for k in required:require(isinstance(c[k],str) and c[k] and '<' not in c[k] and '>' not in c[k],f'Complete configuration field: {k}')
    for k in ('measurements_member','transfusions_member','admissions_member'):require(re.fullmatch(r'[A-Za-z_]\w{0,31}',c[k],flags=re.ASCII) is not None,'Input table names must be valid SAS member names.')
    require(re.fullmatch(r'[A-Za-z0-9_-]{1,64}',c['input_version']) is not None,'Use a short nonidentifying input-version label.')
    require(c['cohort_mode'] in {'full_cohort','development_sample'},'Unknown cohort mode.')
    for k in ('sas_executable','sas_config_file','input_directory','output_directory'):
        p=Path(c[k]).expanduser();require(p.is_absolute(),f'{k} must be absolute.');p=safe_path(p).resolve()
        require(not any(x in str(p) for x in '%&;\r\n\"\''),'Paths cannot contain SAS macro or statement delimiters.')
        c[k]=str(p)
    require(Path(c['sas_config_file']).is_file(),'SAS configuration file not found.')
    source=Path(c['input_directory']);target=Path(c['output_directory'])
    require(not target.is_relative_to(source) and not source.is_relative_to(target),'Input and output directories must be separate.')
    repository=next((p for p in [PACKAGE,*PACKAGE.parents] if (p/'.git').exists()),PACKAGE)
    require(not target.is_relative_to(repository),'Keep generated data and results outside the code repository.')
    return c

def jobs():
    with (PACKAGE/'models.csv').open(encoding='utf-8',newline='') as f:rows=list(csv.DictReader(f))
    require(len(rows)==252 and len({r['JobID'] for r in rows})==252,'The analysis table must contain 252 unique models.')
    return rows

def input_metadata(c):
    result=[]
    for key in ('measurements_member','transfusions_member','admissions_member'):
        p=Path(c['input_directory'])/(c[key]+'.sas7bdat')
        require(p.is_file() and not p.is_symlink(),'An input SAS dataset is missing or is a symbolic link.')
        s=p.stat();result.append({'role':key,'member':c[key],'bytes':s.st_size,'modified_ns':s.st_mtime_ns})
    return result

def prepared_metadata(out):
    return {p.name:{'bytes':p.stat().st_size,'modified_ns':p.stat().st_mtime_ns} for p in sorted((out/'prepared').glob('*.sas7bdat'))}

def sas_value(value):
    text=str(value)
    require(not any(x in text for x in '%&;\r\n\"\''),'Invalid value for SAS configuration.')
    return text

def macro_lines(values):
    lines=[]
    for key,value in values.items():
        require(re.fullmatch('[A-Za-z_][A-Za-z0-9_]*',key) is not None,'Invalid SAS macro variable.')
        lines.append(f'%let {key}={sas_value(value)};')
    return lines

def expected_working(identity,job):
    keys=['RunId','AnalysisSpecId','CohortMode','InputSnapshotId','CodeHash','ConfigHash']
    return {**{k:identity[k] for k in keys},**job,'DesignId':job['JobID']+'_DESIGN','ProfileId':job['JobID']+'_PROFILE'}

def make_program(c,identity,task,step,*,job=None,population=None):
    science=read_json(PACKAGE/'scientific_settings.json');out=Path(c['output_directory'])
    ctx={k:identity[k] for k in ['RunId','AnalysisSpecId','CohortMode','InputSnapshotId','CodeHash','ConfigHash']}
    values={'PACKAGE_ROOT':PACKAGE.as_posix(),'INPUT_DIRECTORY':Path(c['input_directory']).as_posix(),'OUTPUT_DIRECTORY':out.as_posix(),'STEP_DIRECTORY':step.as_posix(),'TASK':task,'SAS_CPU_COUNT':science['SASCPUCount'],'MEASUREMENTS_MEMBER':c['measurements_member'],'TRANSFUSIONS_MEMBER':c['transfusions_member'],'ADMISSIONS_MEMBER':c['admissions_member']}
    expected=None;libraries=[]
    if task=='PREPARE':
        cfg={'RUN_ID':ctx['RunId'],'ANALYSIS_SPEC_ID':ctx['AnalysisSpecId'],'INPUT_SNAPSHOT_ID':ctx['InputSnapshotId'],'CODE_HASH':ctx['CodeHash'],'CONFIG_HASH':ctx['ConfigHash'],'COHORT_MODE':ctx['CohortMode'],'INPUT_MEMBER':c['measurements_member'],'COVERAGE_VERIFIED':'YES','COVERAGE_SCOPE':science['CoverageScope'],'UNITS_VERIFIED':'NO','SCIENCE_FROZEN':'YES' if c['cohort_mode']=='full_cohort' else 'NO'}
        values.update({'CFG_'+k:v for k,v in cfg.items()})
    elif task=='MODEL':
        expected=expected_working(identity,job);ctx.update(expected)
        ctx.update(OptimizerRestart=science['OptimizerRestart'],InferenceScope={'full_cohort':'FULL_COHORT_MODEL_INFERENCE','development_sample':'LOCAL_SAMPLE_MODEL_INFERENCE'}[c['cohort_mode']],CertificateCodeHash=identity['CertificateCodeHash'],ScalarPolicy=science['ScalarAvailabilityPolicy'],StructuralPolicy=science['StructuralInferencePolicy'])
        libraries=[('model','model_tables'),('cr2','inference_tables'),('mcsv','model_csv'),('ccsv','inference_csv')]
    elif task in {'REPORT','LOESS'}:
        preparation=task=='REPORT' and population=='GLOBAL_PREPARATION'
        report_id=uuid.uuid4().hex;export_id=uuid.uuid4().hex
        ctx.update(ReportRunId='NOT_APPLICABLE' if preparation else report_id,ReportCodeHash='NOT_APPLICABLE' if preparation else identity['CodeHash'],ReportConfigHash='NOT_APPLICABLE' if preparation else identity['ConfigHash'],ExportId=export_id,ExportCodeHash=identity['CodeHash'],PopulationId=population,DisclosureStatus='PRIVATE_UNREVIEWED')
        if task=='REPORT':ctx['Bundle']='PREPARATION' if preparation else 'POPULATION'
        else:ctx['PreparationReceiptHash']=identity['PreparationReceiptHash']
        expected=dict(ctx);ctx['OxygenUnits']=science['OxygenUnits'];libraries=[('rpt','report_tables'),('csvout','csv')]
    values.update({'CTX_'+k:v for k,v in ctx.items()})
    lines=['options nosource nosource2 nomprint nomlogic nosymbolgen;','ods _all_ close;']+macro_lines(values)
    if task in {'MODEL','REPORT','LOESS'}:lines.append('libname prep "'+(out/'prepared').as_posix()+'" access=readonly;')
    for lib,folder in libraries:lines.append(f'libname {lib} "{(step/folder).as_posix()}";')
    lines.append('%include "'+(PACKAGE/'run.sas').as_posix()+'";')
    return '\n'.join(lines)+'\n',expected,libraries

def sas_arguments(c, step):
    """Use explicit installation configuration and isolated per-step session files."""
    config = Path(c['sas_config_file'])
    require(config.is_file(), 'SAS configuration file not found.')
    return [
        c['sas_executable'],
        '-config', str(config),
        '-sysin', str(step / 'analysis.sas'),
        '-log', str(step / 'analysis.log'),
        '-print', str(step / 'analysis.lst'),
        '-work', str(step / 'work'),
        '-sasuser', str(step / 'sasuser'),
        '-autoexec', str(step / 'autoexec.sas'),
        '-encoding', 'utf-8', '-noterminal', '-nosplash', '-noxcmd',
    ]


def execute_program(c, identity, step, program, context, folders=()):
    """Run one explicit SAS program in a new isolated output directory.

    Completion records execution only. Numerical validation remains a separate
    requirement, including when a program records an expected unavailable result.
    """
    require(not step.exists(),
            'This analysis step already has an output directory; choose a new output root for a new run.')
    config_hash = file_hash(Path(c['sas_config_file']))
    step.mkdir(parents=True)
    (step / 'work').mkdir()
    (step / 'sasuser').mkdir()
    (step / 'autoexec.sas').write_bytes(b'')
    for folder in folders:
        require(isinstance(folder,str) and re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*',folder), 'Invalid native output folder.')
        (step / folder).mkdir()
    (step / 'analysis.sas').write_text(program, encoding='utf-8')
    write_once(step / 'context.json', context)
    args = sas_arguments(c, step)
    started_ns = time.time_ns()
    with (step / 'startup.stdout.txt').open('wb') as stdout, (step / 'startup.stderr.txt').open('wb') as stderr:
        proc = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            shell=False, cwd=str(step))
    log = ((step / 'analysis.log').read_text(encoding='utf-8', errors='replace')
           if (step / 'analysis.log').exists() else '')
    complete = step / 'completed.txt'
    same_config = config_hash == file_hash(Path(c['sas_config_file']))
    ok = (same_config and proc.returncode in (0, 1)
          and complete.exists()
          and complete.read_text().strip() == 'ANALYSIS_STEP_COMPLETE'
          and not re.search(r'^\s*ERROR(?:\s+\d+-\d+)?:', log, re.M))
    write_once(step / 'execution.json', {
        'completed': ok, 'sasReturnCode': proc.returncode,
        'sourceCodeHash': identity['CodeHash'], 'contextHash': digest(context),
        'started_ns': started_ns,
        'startup': {
            'sasConfigSHA256': config_hash,
            'sasConfigUnchanged': same_config,
            'autoexecSHA256': file_hash(step / 'autoexec.sas'),
            'separateWorkAndSasuser': True,
            'encoding': 'utf-8', 'noXcmd': True,
        },
    })
    require(ok, 'SAS did not complete this step. Inspect its local log and startup output; no result is accepted.')
    return context


def execute(c, identity, task, step, *, job=None, population=None):
    program, expected, libraries = make_program(
        c, identity, task, step, job=job, population=population)
    context = {
        'task': task, 'expected': expected, 'identity': identity,
        'job': job, 'population': population,
        'scientificSettings': read_json(PACKAGE / 'scientific_settings.json'),
    }
    return execute_program(c, identity, step, program, context,
                           folders=[folder for _,folder in libraries])


def main(argv=None):
    runtime=read_json(PACKAGE/'scientific_settings.json')
    for variable in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS'):
        os.environ[variable]=str(runtime['PythonNumericalThreads'])
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['plan','check','prepare','reports','models','loess','validate','convert','weekdays','validate-weekdays','convert-weekdays'])
    parser.add_argument('--config',type=Path,default=PACKAGE/'config.json')
    parser.add_argument('--model',action='append',help='Model ID from models.csv; repeat for multiple models.')
    parser.add_argument('--all-models',action='store_true',help='Explicitly select all 252 model fits.')
    parser.add_argument('--all-weekdays',action='store_true',help='Explicitly select all 42 recorded weekday companions.')
    args=parser.parse_args(argv)
    require(not args.model or args.command in {'models','validate','convert','weekdays','validate-weekdays','convert-weekdays'}, '--model does not apply to this command.')
    require(not args.all_models or args.command=='models', '--all-models applies to model fitting only.')
    require(not args.all_weekdays or args.command in {'weekdays','validate-weekdays','convert-weekdays'}, '--all-weekdays applies to weekday commands only.')
    if args.command=='plan':
        print(json.dumps({'models':len(jobs()),'populations':3,'adjustmentModels':['BASE','FULL'],'outcomes':7,'factorAnalyses':5,'reports':4,'loessReports':1,'weekdayCompanions':42}));return 0
    c=configuration(args.config);out=Path(c['output_directory']);science=read_json(PACKAGE/'scientific_settings.json');code=package_hash()
    if args.command=='prepare':
        require(not out.exists(),'Preparation needs a new output directory.')
        require(Path(c['sas_executable']).is_file(),'SAS executable not found.')
        metadata=input_metadata(c);out.mkdir(parents=True);(out/'prepared').mkdir()
        identity={'RunId':uuid.uuid4().hex,'AnalysisSpecId':'RBC_ANALYSIS_V1','CohortMode':c['cohort_mode'],'InputSnapshotId':digest({'version':c['input_version'],'files':metadata}),'CodeHash':code,'ConfigHash':digest(science),'CertificateCodeHash':file_hash(PACKAGE/'sas/04_inference.sas')}
        execute(c,identity,'PREPARE',out/'preparation')
        record={'identity':identity,'inputMetadata':metadata,'preparedMetadata':prepared_metadata(out)}
        require(bool(record['preparedMetadata']),'Preparation produced no native tables.')
        write_once(out/'preparation.json',record)
        print('Preparation completed. Run reports, selected models and LOESS explicitly.');return 0
    if args.command=='check':
        require(Path(c['sas_executable']).is_file(),'SAS executable not found.')
        require(not out.exists(),'Installation check needs a new output directory.')
        out.mkdir(parents=True)
        identity={'RunId':uuid.uuid4().hex,'AnalysisSpecId':'RBC_ANALYSIS_V1','CohortMode':c['cohort_mode'],'InputSnapshotId':'0'*64,'CodeHash':code,'ConfigHash':digest(science),'CertificateCodeHash':file_hash(PACKAGE/'sas/04_inference.sas')}
        execute(c,identity,'CHECK',out/'installation_check');print('SAS macro definitions loaded. This is not an end-to-end analysis test.');return 0
    require((out/'preparation.json').is_file(),'Complete preparation first.')
    prepared=read_json(out/'preparation.json');identity=prepared['identity']
    require(identity['CodeHash']==code and identity['ConfigHash']==digest(science) and identity['CohortMode']==c['cohort_mode'],'Code or scientific configuration changed after preparation.')
    require(prepared['preparedMetadata']==prepared_metadata(out),'Prepared tables changed after preparation.')
    identity={**identity,'PreparationReceiptHash':file_hash(out/'preparation.json')}
    if args.command in {'weekdays','validate-weekdays','convert-weekdays'}:
        import weekday_steps
        selected=weekday_steps.select_ids(args.model,args.all_weekdays)
        lookup={j['JobID']:j for j in jobs()};plan=weekday_steps.plans()
        for key in selected:
            step=out/'weekdays'/key
            if args.command=='weekdays':weekday_steps.run_step(c,identity,lookup[key],plan[key])
            elif args.command=='validate-weekdays':weekday_steps.validate_step(step)
            else:weekday_steps.convert_step(step)
            print(key+': '+args.command+' completed.',flush=True)
        return 0
    if args.command=='convert':
        from convert_results import convert_directory
        convert_directory(out,model_ids=args.model);return 0
    if args.command=='validate':
        from validate import validate_directory
        validate_directory(out,model_ids=args.model);return 0
    if args.command=='models':
        require(args.all_models != bool(args.model),'Choose --all-models or one or more --model IDs.')
        lookup={j['JobID']:j for j in jobs()};selected=list(lookup) if args.all_models else args.model
        require(len(set(selected))==len(selected) and set(selected)<=set(lookup),'Unknown or duplicate model selection.')
        for key in selected:
            execute(c,identity,'MODEL',out/'models'/key,job=lookup[key]);print(key+': SAS completed; independent validation pending.',flush=True)
    elif args.command=='reports':
        for pop in ['GLOBAL_PREPARATION','PRIMARY','FIRST_EVENT','NO_FOLLOWING_UNIT_12H']:
            execute(c,identity,'REPORT',out/'reports'/pop,population=pop);print(pop+': report completed.',flush=True)
    elif args.command=='loess':execute(c,identity,'LOESS',out/'loess',population='PRIMARY');print('LOESS completed; independent validation pending.')
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (AnalysisError,OSError,ValueError) as error:
        print(str(error),file=sys.stderr);raise SystemExit(1)

