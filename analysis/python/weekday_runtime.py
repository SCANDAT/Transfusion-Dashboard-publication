"""Sequential donation-day inference from retained model outputs.

Retain the original seven-day fit status when computing the weekday contrasts.
"""
from pathlib import Path
import csv
import hashlib
import json
import re
import shutil
from weekday_stage import stage_candidate

PACKAGE=Path(__file__).resolve().parents[1]
ROLES=('identity status working_target cat_availability family_plan contrast_plan target_keys target_design '
       'joint_design joint_rank_audit all_targets levels changes within pairwise joint si_basis si_bread si_covariance '
       'si_spanbasis si_spanrobust si_moment si_moment_error si_solution si_context si_status si_inference '
       'si_scalar_weights si_scalar_certificate joint_weights joint_certificate certificate_context scalar_unavailable si_root_summary').split()
MODEL_ROLES=('identity job_status fitmetadata solution covparms columns column_scale score_design anchor_design '
             'categories cat_availability family_plan contrast_plan trajectory profile').split()

def need(ok,message):
    if not ok:raise ValueError(message)

def sha(path):
    with Path(path).open('rb')as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def read_json(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def write_json(path,value):
    with Path(path).open('x',encoding='utf-8',newline='\n')as stream:
        json.dump(value,stream,sort_keys=True,allow_nan=False);stream.write('\n')

def safe(value):
    value=str(value)
    need(not any(c in value for c in '%&;\r\n\"\''),'Invalid SAS configuration value.')
    return value

def native_path(directory,name):
    direct=Path(directory)/(name+'.sas7bdat')
    if direct.is_file():return direct
    matches=[p for p in Path(directory).iterdir()if p.is_file()and p.name.lower()==(name+'.sas7bdat').lower()]
    need(len(matches)==1,'A required retained model member is missing or ambiguous.')
    return matches[0]

def binding(path):return {'Path':str(path),'SHA256':sha(path)}

def inspect_native_csv(path):
    with Path(path).open(encoding='utf-8-sig',newline='')as stream:return list(csv.DictReader(stream))

def native_program(*,step,job,model_dir,saved_dir,scope,certificate,mode,capture=False,
                   candidate_dir=None,candidate_id='NONE',allow_residual_failure=False):
    step=Path(step);job_id=job['JobID'];prefix='C'+job_id[1:]
    need(re.fullmatch(r'M[0-9]{4}',job_id),'Invalid model identifier.')
    need(mode in {'REUSE','SAVED'},'Invalid weekday construction mode.')
    for value in [step,model_dir,saved_dir,PACKAGE,certificate,scope,candidate_id]:safe(value)
    if candidate_dir is not None:safe(candidate_dir)
    corrected=candidate_dir is not None
    status_protocol=(job_id+'_FIXED_COVARIANCE_CANDIDATE_NATIVE_V1'if corrected else 'MONDAY_FRIDAY_SAVED_PILOT_NATIVE_V1')
    complete_protocol=(job_id+'_FIXED_COVARIANCE_CANDIDATE_EXPORT_COMPLETE_V1'if corrected else 'MONDAY_FRIDAY_SAVED_PILOT_EXPORT_COMPLETE_V1')
    declarations=f'''options nosource nosource2 nomprint nomlogic nosymbolgen cpucount=1;
ods _all_ close;
%include "{PACKAGE.as_posix()}/sas/03_models.sas";
%include "{PACKAGE.as_posix()}/sas/06_exports.sas";
%include "{PACKAGE.as_posix()}/sas/07_weekday.sas";
%let RBC_MF_BOUND_JOB={job_id};
%let RBC_MF_ORIGINAL_CONSTRUCTION={certificate};
%macro weekday_run;
%local role i present;
'''
    if corrected:
        declarations+=f'''%global RBC_WEEKDAY_CORRECTION_OK;
%let RBC_WEEKDAY_CORRECTION_OK=YES;
%rbc_weekday_stage_candidate(meanpath={Path(model_dir).as_posix()},qrpath={Path(saved_dir).as_posix()},
 stage={Path(candidate_dir).as_posix()},job_id={job_id},prefix={prefix});
'''
        model_dir=Path(candidate_dir)/'models';saved_dir=Path(candidate_dir)/'saved'
    declarations+=f'''libname MODEL "{Path(model_dir).as_posix()}" access=readonly;
libname SAVED "{Path(saved_dir).as_posix()}" access=readonly;
libname OUT "{step.as_posix()}/native";
'''
    if capture:
        declarations+=f'''libname GEOMETRY "{step.as_posix()}/geometry";
%global RBC_WEEKDAY_CAPTURE_LIB;
%let RBC_WEEKDAY_CAPTURE_LIB=GEOMETRY;
'''
    if mode=='REUSE':
        declarations+=f'''%rbc_mf_accepted_reuse(model_lib=MODEL,job_id={job_id},saved_cr2=SAVED,accepted_cr2=SAVED,
 outlib=OUT,prefix={prefix},scope={scope},alpha=.05,certificate_hash={certificate},
 scalar_policy=LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1);
'''
    else:
        declarations+=f'''%rbc_mf_saved_integration(model_lib=MODEL,job_id={job_id},saved_cr2=SAVED,
 outlib=OUT,prefix={prefix},scope={scope},alpha=.05,certificate_hash={certificate},
 scalar_policy=LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1);
'''
    marker_fields=(f'"FixedCovarianceMeanSolutionUsed":true,"OriginalMeanArchiveChanged":false,"VarianceRefitPerformed":false,"CandidateMeanID":"{candidate_id}"'
                   if corrected else '"MeanRefitPerformed":false,"OriginalSevenDayStatusChanged":false')
    if mode=='REUSE':marker_fields+=',"ExecutionMode":"ACCEPTED_FULL_SPAN_REUSE"'
    declarations+=f'''data _null_;
 file "{step.as_posix()}/producer_status.json";
 put '{{"Protocol":"{status_protocol}","JobID":"{job_id}","ProducerIntegrationPASS":' "&RBC_CR2_INTEGRATION_OK" ',"ReasonCode":"' "&RBC_CR2_INTEGRATION_REASON" '",{marker_fields}}}';
run;
%if &syscc>4 or &syserr>4 %then %abort cancel;
'''
    if allow_residual_failure:
        declarations+=f'''%if &RBC_CR2_INTEGRATION_OK ne 1 %then %do;
 %if %superq(RBC_CR2_INTEGRATION_REASON) ne EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH %then %abort cancel;
 data _null_;file "{step.as_posix()}/completed.txt";put 'ANALYSIS_STEP_COMPLETE';run;
 %return;
%end;
'''
    else:declarations+='%if &RBC_CR2_INTEGRATION_OK ne 1 %then %abort cancel;\n'
    declarations+=f'''%let roles={' '.join(ROLES)};
%do i=1 %to %sysfunc(countw(&roles));
 %let role=%scan(&roles,&i);
 %if %sysfunc(exist(OUT.{prefix}_&role,DATA)) %then %do;
  filename wdout "{step.as_posix()}/csv/{prefix}_&role..csv";
  %if %sysfunc(exist(work._rbc_weekday_export,DATA))
  or %sysfunc(exist(work._rbc_weekday_export,VIEW)) %then %abort cancel;
 data work._rbc_weekday_export;set OUT.{prefix}_&role;run;
 %if &syscc>4 or &syserr>4 %then %abort cancel;
 %rbc_export_exact_csv(data=work._rbc_weekday_export,fileref=wdout);
  %if &RBC_EXACT_CSV_OK ne 1 %then %abort cancel;
  filename wdout clear;
  proc datasets library=work nolist;delete _rbc_weekday_export;quit;
  %if &syscc>4 or &syserr>4 %then %abort cancel;
 %end;
%end;
%let roles=score_design anchor_design solution fitmetadata identity trajectory;
%do i=1 %to %sysfunc(countw(&roles));
 %let role=%scan(&roles,&i);
 filename wdout "{step.as_posix()}/csv/original_{job_id}_&role..csv";
 %if %sysfunc(exist(work._rbc_weekday_export,DATA))
  or %sysfunc(exist(work._rbc_weekday_export,VIEW)) %then %abort cancel;
 data work._rbc_weekday_export;set MODEL.{job_id}_&role;run;
 %if &syscc>4 or &syserr>4 %then %abort cancel;
 %rbc_export_exact_csv(data=work._rbc_weekday_export,fileref=wdout);
 %if &RBC_EXACT_CSV_OK ne 1 %then %abort cancel;
 filename wdout clear;
 proc datasets library=work nolist;delete _rbc_weekday_export;quit;
 %if &syscc>4 or &syserr>4 %then %abort cancel;
%end;
data _null_;
 file "{step.as_posix()}/native_complete.json";
 put '{{"Protocol":"{complete_protocol}","JobID":"{job_id}","NativeExportComplete":true,{marker_fields}}}';
run;
%if &syscc>4 or &syserr>4 %then %abort cancel;
data _null_;file "{step.as_posix()}/completed.txt";put 'ANALYSIS_STEP_COMPLETE';run;
%mend;
%weekday_run;
'''
    if mode=='REUSE':
        reuse={'Protocol':'MONDAY_FRIDAY_ACCEPTED_FULL_SPAN_REUSE_V1',
               'ExecutionMode':'ACCEPTED_FULL_SPAN_REUSE','JobID':job_id,
               'OriginalMomentConstructionSourceSHA256':certificate,'ReusedScalarResults':True,
               'ReusedFullSpanMatrices':True,'FullMomentReconstructionPerformed':False,
               'RecomputedJointTests':[1,2],'MeanRefitPerformed':False,'OriginalSevenDayStatusChanged':False}
        record=json.dumps(reuse,separators=(',',':'))
        declarations+=f'data _null_;file "{step.as_posix()}/reuse_provenance.json";put \'{record}\';run;\n'
    return declarations


def split_exact_roles(native_step,output_step,job_id,profile_csv):
    """Select the frozen delivery fields without changing any CSV cell values."""
    exact=Path(output_step)/'exact';exact.mkdir()
    prefix='C'+job_id[1:]
    schemas=read_json(PACKAGE/'results/weekday_schema.json')['roles']
    def project(role,source,label=None):
        with Path(source).open(encoding='utf-8-sig',newline='')as stream:
            reader=csv.DictReader(stream,strict=True);headers=reader.fieldnames;values=list(reader)
        need(headers and len(headers)==len(set(headers)) and
             all(None not in row and None not in row.values()for row in values),
             'WEEKDAY_SOURCE_TABLE_SCHEMA')
        variants=schemas[role];known=set().union(*(set(v)for v in variants))
        present=set(headers)&known
        matches=[v for v in variants if set(v)==present]
        need(len(matches)==1,'WEEKDAY_SOURCE_PROJECTION_SCHEMA')
        fields=list(matches[0])
        if label is not None:
            values=[row for row in values if row['TestRole']==label]
            need(len(values)==1,'Each weekday joint role must occur once.')
        with (exact/(role+'.csv')).open('x',encoding='utf-8',newline='')as stream:
            writer=csv.DictWriter(stream,fieldnames=fields,lineterminator='\n')
            writer.writeheader();writer.writerows({field:row[field]for field in fields}for row in values)
    for role in ['levels','changes','within','pairwise']:
        project(role,Path(native_step)/'csv'/(prefix+'_'+role+'.csv'))
    joint=Path(native_step)/'csv'/(prefix+'_joint.csv')
    for role,label in [('endpoint_joint','MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY'),
                       ('trajectory_joint','MONDAY_FRIDAY_TRAJECTORY_INTERACTION')]:
        project(role,joint,label)
    project('reference_profile',profile_csv)


def run_weekday(c,identity,job,model_step,output_step,execute_program,plan,selection):
    """Execute only the explicitly declared method, without accepting inference."""
    job_id=job['JobID'];prefix='C'+job_id[1:];model_step=Path(model_step);output_step=Path(output_step)
    need(plan['JobID']==job_id and job['FactorName']=='wdy_donation'
         and all(plan[k]==job[k]for k in ['FitId','PopulationId','Model','VitalCode']), 'Weekday plan differs from model.')
    need(plan['ReferenceCategory']=='2' and plan['ReportedCategories']=='2 3 4 5 6'
         and plan['HolmFamilySize']=='10','Weekday reporting family differs from specification.')
    method=plan['Method'];need(method in {'REUSE_ACCEPTED_INFERENCE','SAVED_ORIGINAL_MEAN','FIXED_COVARIANCE_CORRECTION'},'Unrecognized weekday method.')
    need(output_step.is_dir() and not any(output_step.iterdir()),'A new empty weekday output directory is required.')
    parent_context=read_json(model_step/'context.json')
    working=read_json(model_step/'working_validation.json')
    need(working.get('validation',{}).get('status')=='VALIDATED','Independent original working-model validation is required.')
    if method=='REUSE_ACCEPTED_INFERENCE':
        accepted=read_json(model_step/'validation.json')
        need(accepted.get('validation',{}).get('status')=='VALIDATED','Accepted full-span CR2 is required for covariance reuse.')
    parent_files=[]
    for folder in ['model_csv','inference_csv']:
        for path in sorted((model_step/folder).glob('*.csv')):parent_files.append(binding(path))
    model_dir=model_step/'model_tables';saved_dir=model_step/'inference_tables'
    for role in MODEL_ROLES:
        parent_files.append(binding(native_path(model_dir,job_id+'_'+role)))
    for role in ['cs_qr','cs_solution','cs_context','cs_support','cs_status']:
        parent_files.append(binding(native_path(saved_dir,prefix+'_'+role)))
    if method=='REUSE_ACCEPTED_INFERENCE':
        for role in ('identity all_targets si_basis si_bread si_covariance si_spanbasis si_spanrobust '
                     'si_moment si_moment_error si_solution si_context si_status si_inference '
                     'si_scalar_weights si_scalar_certificate certificate_context').split():
            parent_files.append(binding(native_path(saved_dir,prefix+'_'+role)))
    source_sha=sha(PACKAGE/'sas/07_weekday.sas');certificate=source_sha
    if method=='REUSE_ACCEPTED_INFERENCE':
        cc=inspect_native_csv(model_step/'inference_csv'/(prefix+'_certificate_context.csv'))
        need(len(cc)==1 and re.fullmatch('[0-9a-f]{64}',cc[0]['ConstructionSourceSHA256']), 'Original covariance construction binding missing.')
        certificate=cc[0]['ConstructionSourceSHA256']
    scope={'full_cohort':'FULL_COHORT_MODEL_INFERENCE','development_sample':'LOCAL_SAMPLE_MODEL_INFERENCE'}[c['cohort_mode']]
    context={'task':'WEEKDAY','job':job,'identity':identity,'expected':parent_context['expected'],
             'parentIdentity':parent_context['expected'],'parentFiles':parent_files,
             'parent':{'directory':str(model_step),'contextSHA256':sha(model_step/'context.json'),
                       'executionSHA256':sha(model_step/'execution.json'),
                       'workingValidationSHA256':sha(model_step/'working_validation.json'),
                       'meanFitSHA256':parent_context['expected']['CodeHash']},
             'scientificSettings':read_json(PACKAGE/'scientific_settings.json'),
             'weekdaySettings':read_json(PACKAGE/'weekday_settings.json'),'plan':plan,
             'nativeProducerSHA256':source_sha,'originalConstructionSHA256':certificate}
    first=output_step/('native_initial'if method=='FIXED_COVARIANCE_CORRECTION'else 'native_pass')
    program=native_program(step=first,job=job,model_dir=model_dir,saved_dir=saved_dir,scope=scope,
          certificate=certificate,mode='REUSE'if method=='REUSE_ACCEPTED_INFERENCE'else 'SAVED',
          capture=method=='FIXED_COVARIANCE_CORRECTION',allow_residual_failure=method=='FIXED_COVARIANCE_CORRECTION')
    execute_program(c,identity,first,program,{**context,'stage':'INITIAL'},folders=['native','csv','geometry'])
    status=read_json(first/'producer_status.json');corrected=False;candidate_id='NONE';final=first
    need(not(method=='FIXED_COVARIANCE_CORRECTION' and status['ProducerIntegrationPASS']==1),
         'UNEXPECTED_ORIGINAL_PASS_FOR_DECLARED_CORRECTION')
    if status['ProducerIntegrationPASS']!=1:
        need(method=='FIXED_COVARIANCE_CORRECTION'and status['ReasonCode']=='EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH',
             'No correction is authorized for this failure.')
        need(plan['CorrectionEligibility']=='RECORDED_RESIDUAL_MISMATCH','Correction policy is missing.')
        candidate_id=job_id+'_FIXED_COVARIANCE_GLS_V1'
        inputs={name:binding(native_path(first/'geometry',member))for name,member in
                [('basis','capture_basis'),('beta','capture_beta'),('params','capture_params'),('global_factor','capture_globalfactor')]}
        inputs['qr']=binding(native_path(saved_dir,prefix+'_cs_qr'))
        inputs['score']=binding(native_path(model_dir,job_id+'_score_design'))
        candidate=output_step/'candidate'
        stage_candidate(inputs=inputs,output=candidate,job_id=job_id,candidate_id=candidate_id,
                        failure_reason=status['ReasonCode'],method=method,eligible_jobs={job_id})
        final=output_step/'native_pass'
        program=native_program(step=final,job=job,model_dir=model_dir,saved_dir=saved_dir,scope=scope,
                  certificate=source_sha,mode='SAVED',candidate_dir=candidate,candidate_id=candidate_id)
        execute_program(c,identity,final,program,{**context,'stage':'CORRECTED','CandidateMeanID':candidate_id},folders=['native','csv','geometry'])
        corrected=True
    final_status=read_json(final/'producer_status.json')
    need(final_status['ProducerIntegrationPASS']==1,'Weekday native inference is incomplete.')
    for ref in parent_files:need(sha(ref['Path'])==ref['SHA256'],'An original retained input changed.')
    native_identity=inspect_native_csv(final/'csv'/(prefix+'_identity.csv'))
    pair=inspect_native_csv(final/'csv'/(prefix+'_pairwise.csv'))
    need(len(native_identity)==1 and len(pair)==10,'Weekday output cardinality differs from its specification.')
    families={row['FamilyID']for row in pair};need(len(families)==1,'Weekday family identifiers differ.')
    selection=dict(selection)
    selection.update(InferenceScope='MONDAY_FRIDAY',TargetSetID=native_identity[0]['TargetSetID'],
          HolmFamilyID=next(iter(families)),MeanSolutionKind='FIXED_COVARIANCE_GLS_RECOVERY'if corrected else 'ORIGINAL_FIT',
          CandidateMeanID=candidate_id,OriginalMeanOriginIsParentProvenanceOnly=int(corrected),
          ScalarDFMethod='CONTRAST_SATTERTHWAITE',JointDFMethod='HTZ')
    context.update(selection=selection,nativeDirectory=str(final),appliedBranch='FIXED_COVARIANCE_CORRECTION'if corrected else method,
                   candidateLineage=str(output_step/'candidate/lineage.json')if corrected else None)
    split_exact_roles(final,output_step,job_id,model_step/'model_csv'/(job_id+'_profile.csv'))
    def stage_binding(stage):
        return {'directory':str(stage),'contextSHA256':sha(stage/'context.json'),
                'executionSHA256':sha(stage/'execution.json'),
                'programSHA256':sha(stage/'analysis.sas'),
                'producerStatusSHA256':sha(stage/'producer_status.json'),
                'completeMarkerSHA256':sha(stage/'completed.txt'),
                'nativeCompleteSHA256':sha(stage/'native_complete.json')
                    if (stage/'native_complete.json').is_file() else None}
    stages=[stage_binding(first)]
    if final!=first:stages.append(stage_binding(final))
    return {'selection':selection,'completed':True,'stages':stages,
            'nativeDirectory':str(final),'parentFiles':parent_files,
            'candidateLineage':context['candidateLineage'],'appliedBranch':context['appliedBranch'],
            'nativeProducerSHA256':source_sha,'originalConstructionSHA256':certificate,
            'originalInferenceStatusChanged':False}
