"""Run, validate and convert the approved Monday-Friday companions."""
from __future__ import annotations
import csv,io,json,time,uuid
from pathlib import Path
from file_utils import digest,write_once,safe_path

ROLES=('levels','changes','within','pairwise','endpoint_joint','trajectory_joint','reference_profile')

def require(ok,code):
    if not ok: raise ValueError(code)

def plans():
    from run import PACKAGE,jobs
    with (PACKAGE/'weekday_models.csv').open(encoding='utf-8-sig',newline='') as stream:
        rows=list(csv.DictReader(stream))
    lookup={r['JobID']:r for r in rows};models={r['JobID']:r for r in jobs()}
    require(len(rows)==42 and len(lookup)==42,'WEEKDAY_PLAN_SIZE')
    expected={k for k,v in models.items() if v['FactorName']=='wdy_donation'}
    require(set(lookup)==expected,'WEEKDAY_PLAN_MEMBERSHIP')
    counts={}
    for key,row in lookup.items():
        require(all(row.get(field)==value for field,value in models[key].items()),'WEEKDAY_MODEL_DEFINITION')
        require(row['ReferenceCategory']=='2' and row['ReportedCategories']=='2 3 4 5 6'
                and row['HolmFamilySize']=='10','WEEKDAY_TARGET_DEFINITION')
        counts[row['Method']]=counts.get(row['Method'],0)+1
    require(counts=={'REUSE_ACCEPTED_INFERENCE':14,'SAVED_ORIGINAL_MEAN':1,
                    'FIXED_COVARIANCE_CORRECTION':27},'WEEKDAY_BRANCH_COUNTS')
    return lookup

def select_ids(model_ids,all_weekdays=False):
    lookup=plans()
    require(bool(model_ids)!=bool(all_weekdays),'SELECT_WEEKDAY_MODELS_OR_ALL_WEEKDAYS')
    selected=list(lookup) if all_weekdays else list(model_ids)
    require(len(selected)==len(set(selected)) and set(selected)<=set(lookup),'UNKNOWN_OR_DUPLICATE_WEEKDAY_MODEL')
    return selected

def run_step(c,identity,job,plan):
    from run import PACKAGE,file_hash,read_json,execute_program
    from validate import validate_working_step
    from weekday_runtime import run_weekday
    root=Path(c['output_directory']);parent=root/'models'/job['JobID'];step=root/'weekdays'/job['JobID']
    require(not step.exists(),'WEEKDAY_OUTPUT_ALREADY_EXISTS')
    validate_working_step(parent,identity)
    parent_context=read_json(parent/'context.json')
    parent_binding={'contextSHA256':file_hash(parent/'context.json'),
        'executionSHA256':file_hash(parent/'execution.json'),
        'workingValidationSHA256':file_hash(parent/'working_validation.json'),
        'meanFitSHA256':parent_context['expected']['CodeHash']}
    step.mkdir(parents=True);started_ns=time.time_ns()
    result=run_weekday(c,identity,job,parent,step,execute_program,plan,{})
    require(result.get('completed') is True,'WEEKDAY_NATIVE_NOT_COMPLETED')
    selected=result['selection']
    context={'schemaVersion':'transfusion-analysis/weekday-context-v1','task':'WEEKDAY',
        'job':job,'identity':identity,'expected':parent_context['expected'],
        'parentIdentity':parent_context['identity'],'parent':parent_binding,
        'scientificSettings':read_json(PACKAGE/'scientific_settings.json'),
        'weekdaySettings':read_json(PACKAGE/'weekday_settings.json'),
        'plan':plan,'selection':selected}
    write_once(step/'context.json',context)
    write_once(step/'execution.json',{'completed':True,'contextHash':digest(context),
        'sourceCodeHash':identity['CodeHash'],'started_ns':started_ns,
        'result':{k:v for k,v in result.items() if k not in {'completed','selection'}}})
    check_bindings(step)
    return context

def check_bindings(step):
    from run import PACKAGE,file_hash,read_json,package_hash,prepared_metadata
    step=safe_path(step);root=step.parent.parent
    require(step.parent.name=='weekdays' and step.name in plans(),'WEEKDAY_STEP_LOCATION')
    context=read_json(step/'context.json');execution=read_json(step/'execution.json')
    require(context['task']=='WEEKDAY' and context['schemaVersion']=='transfusion-analysis/weekday-context-v1','WEEKDAY_CONTEXT_SCHEMA')
    require(context['job']['JobID']==step.name and context['plan']==plans()[step.name],'WEEKDAY_PLAN_CHANGED')
    require(execution.get('completed') is True and execution.get('contextHash')==digest(context),'WEEKDAY_EXECUTION_REQUIRED')
    preparation=read_json(root/'preparation.json')
    identity={**preparation['identity'],'PreparationReceiptHash':file_hash(root/'preparation.json')}
    require(identity==context['identity'] and identity['CodeHash']==package_hash()
            and execution['sourceCodeHash']==identity['CodeHash'],'WEEKDAY_CODE_OR_PREPARATION_CHANGED')
    require(preparation['preparedMetadata']==prepared_metadata(root),'PREPARED_TABLES_CHANGED')
    require(context['scientificSettings']==read_json(PACKAGE/'scientific_settings.json')
            and context['weekdaySettings']==read_json(PACKAGE/'weekday_settings.json'),'WEEKDAY_SETTINGS_CHANGED')
    parent=root/'models'/step.name
    for field,name in [('contextSHA256','context.json'),('executionSHA256','execution.json'),
                       ('workingValidationSHA256','working_validation.json')]:
        require(context['parent'][field]==file_hash(parent/name),'WEEKDAY_PARENT_CHANGED')
    pctx=read_json(parent/'context.json');w=read_json(parent/'working_validation.json')
    require(context['parentIdentity']==pctx['identity'] and context['expected']==pctx['expected']
            and context['parent']['meanFitSHA256']==pctx['expected']['CodeHash'],'WEEKDAY_MEAN_LINEAGE_CHANGED')
    require(w['validation']['status']=='VALIDATED' and w['validation']['scope']=='WORKING_MODEL_ONLY','WEEKDAY_PARENT_WORKING_VALIDATION')
    check_parent_archives(parent,context['plan']['Method'])
    return context,execution

def check_parent_archives(parent,method):
    from run import read_json
    from validate import model_archive_hashes
    execution=read_json(parent/'execution.json');working=read_json(parent/'working_validation.json')
    require(model_archive_hashes(parent/'model_csv',execution['started_ns'])
            ==working['validation']['inputHashes'],'WEEKDAY_PARENT_WORKING_ARCHIVE_CHANGED')
    if method=='REUSE_ACCEPTED_INFERENCE':
        accepted=read_json(parent/'validation.json')
        require(accepted.get('contextHash')==working['contextHash']
                and accepted.get('validation',{}).get('status')=='VALIDATED',
                'WEEKDAY_ACCEPTED_PARENT_INFERENCE_REQUIRED')
        require(model_archive_hashes(parent/'inference_csv',execution['started_ns'])
                ==accepted['validation']['inputHashes']['robust'],
                'WEEKDAY_PARENT_ACCEPTED_COVARIANCE_CHANGED')

def input_hashes(step,paths):
    from run import file_hash
    root=safe_path(step)
    result={}
    for rel in paths:
        p=Path(rel)
        require(not p.is_absolute() and '..' not in p.parts,'WEEKDAY_INPUT_PATH_INVALID')
        target=safe_path(root/p)
        require(target.is_file() and target.is_relative_to(root),'WEEKDAY_INPUT_REQUIRED')
        result[rel]=file_hash(target)
    return result

def validate_step(step):
    from run import read_json,file_hash
    from weekday_validation import validate_weekday_step
    context,_=check_bindings(step)
    before={str(p):file_hash(step/p) for p in ('context.json','execution.json')}
    target=step/'validation.json'
    if target.exists():
        receipt=read_json(target);result=receipt.get('validation',{})
        require(receipt.get('contextHash')==digest(context) and result.get('status')=='VALIDATED','WEEKDAY_VALIDATION_CHANGED')
        require(input_hashes(step,result['inputHashes'])==result['inputHashes'],'WEEKDAY_VALIDATED_INPUT_CHANGED')
        return result
    result=validate_weekday_step(step,context)
    require(result.get('status')=='VALIDATED','WEEKDAY_INDEPENDENT_VALIDATION_REQUIRED')
    expected={f'exact/{role}.csv' for role in ROLES}
    require(expected<=set(result.get('inputHashes',{})),'WEEKDAY_SELECTED_ROLE_BINDINGS_REQUIRED')
    require(input_hashes(step,result['inputHashes'])==result['inputHashes'],'WEEKDAY_VALIDATED_INPUT_CHANGED')
    check_bindings(step)
    require(before=={p:file_hash(step/p) for p in before},'WEEKDAY_CONTEXT_CHANGED_DURING_VALIDATION')
    write_once(target,{'contextHash':digest(context),'validation':result})
    return result

def schema_chars(role,raw):
    from run import PACKAGE,read_json
    variants=read_json(PACKAGE/'results/weekday_schema.json')['roles'][role]
    reader=csv.reader(io.StringIO(raw.decode('utf-8-sig'),newline=''),strict=True)
    header=next(reader)
    require(len(header)==len(set(header)),'WEEKDAY_DUPLICATE_COLUMNS')
    matches=[v for v in variants if set(v)==set(header)]
    require(len(matches)==1 and set(matches[0].values())<={'numeric','char'},'WEEKDAY_EXACT_ROLE_SCHEMA')
    return {name for name,kind in matches[0].items() if kind=='char'}

def convert_step(step):
    from run import read_json,file_hash
    from csv_formats import convert_csv
    context,_=check_bindings(step);receipt=read_json(step/'validation.json')
    result=receipt['validation'];validation_hash=file_hash(step/'validation.json')
    require(receipt['contextHash']==digest(context) and result['status']=='VALIDATED','WEEKDAY_VALIDATION_REQUIRED')
    expected={f'exact/{role}.csv' for role in ROLES}
    require(expected<=set(result['inputHashes']),'WEEKDAY_SELECTED_ROLE_BINDINGS_REQUIRED')
    require(input_hashes(step,result['inputHashes'])==result['inputHashes'],'WEEKDAY_VALIDATED_INPUT_CHANGED')
    destination=step/'decimal_csv'
    if destination.exists():
        conversion=read_json(destination/'conversion.json')
        entries=conversion.get('files',[])
        require(conversion.get('validationSha256')==validation_hash
                and conversion.get('numericFormat')=='PY_REPR_BINARY64'
                and conversion.get('publicReleaseAuthorized') is False,'WEEKDAY_CONVERSION_CHANGED')
        require(len(entries)==7 and {e['file'] for e in entries}=={r+'.csv'for r in ROLES},'WEEKDAY_CONVERSION_ROLE_SET')
        require({p.name for p in destination.iterdir()}=={r+'.csv'for r in ROLES}|{'conversion.json'},'WEEKDAY_DECIMAL_FILE_SET')
        for entry in entries:
            require(entry['sourceSha256']==result['inputHashes']['exact/'+entry['file']]
                    and entry['decimalSha256']==file_hash(safe_path(destination/entry['file'])),'WEEKDAY_DECIMAL_CHANGED')
    else:
        stage=step/('.decimal_csv_'+uuid.uuid4().hex+'.incomplete');stage.mkdir()
        entries=[]
        for role in ROLES:
            source=step/'exact'/(role+'.csv');raw=source.read_bytes()
            require(file_hash(source)==result['inputHashes']['exact/'+source.name],'WEEKDAY_SOURCE_CHANGED')
            payload=convert_csv(raw,schema_chars(role,raw))
            (stage/source.name).write_bytes(payload)
            entries.append({'file':source.name,'sourceSha256':result['inputHashes']['exact/'+source.name],
                            'decimalSha256':file_hash(stage/source.name)})
        require(input_hashes(step,result['inputHashes'])==result['inputHashes'],'WEEKDAY_INPUT_CHANGED_DURING_CONVERSION')
        require(file_hash(step/'validation.json')==validation_hash,'WEEKDAY_VALIDATION_CHANGED_DURING_CONVERSION')
        write_once(stage/'conversion.json',{'numericFormat':'PY_REPR_BINARY64','validationSha256':validation_hash,
            'files':entries,'publicReleaseAuthorized':False})
        require(not destination.exists(),'WEEKDAY_DECIMAL_ALREADY_EXISTS');stage.rename(destination)
    check_bindings(step)
    selection={'schemaVersion':'transfusion-analysis/weekday-selection-v1','JobID':context['job']['JobID'],
        'contextSHA256':file_hash(step/'context.json'),'executionSHA256':file_hash(step/'execution.json'),
        'validationSHA256':validation_hash,'conversionSHA256':file_hash(destination/'conversion.json')}
    if (step/'selection.json').exists():
        require(read_json(step/'selection.json')==selection,'WEEKDAY_SELECTION_CHANGED')
    else:write_once(step/'selection.json',selection)
    return 7
