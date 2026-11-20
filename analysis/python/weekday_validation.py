"""Bind portable weekday results to independent numerical validation.

Working models, original inference and corrected coefficient solutions retain
separate provenance. This module does not fit models or read source observations.
"""
from pathlib import Path
import csv, hashlib, json, re
import numpy as np
from threadpoolctl import threadpool_limits
from file_utils import safe_path
import weekday_validation_core as core
import validate_weekday_coefficients as candidate

PACKAGE=Path(__file__).resolve().parents[1]
ROLES=('levels','changes','within','pairwise','endpoint_joint','trajectory_joint','reference_profile')
METHOD_MAP={'REUSE_ACCEPTED_INFERENCE':'ACCEPTED_REUSE','SAVED_ORIGINAL_MEAN':'SAVED_ORIGINAL','FIXED_COVARIANCE_CORRECTION':'FIXED_COVARIANCE_CORRECTION'}
METHODS=set(METHOD_MAP.values())

def need(ok,code):
    if not ok:raise ValueError(code)

def read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def canonical(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),
        ensure_ascii=True,allow_nan=False).encode()).hexdigest()

def bounded(path,root):
    path=Path(path)
    if not path.is_absolute():path=Path(root)/path
    resolved=safe_path(path).resolve()
    need(resolved.is_relative_to(Path(root).resolve()) and not path.is_symlink(),'VALIDATION_PATH_SCOPE')
    return resolved

def reference(path):
    path=safe_path(path);need(path.is_file() and not path.is_symlink(),'VALIDATION_INPUT_MISSING')
    before=path.stat();result={'Path':str(path),'SHA256':core.sha(path)};after=path.stat()
    need((before.st_size,before.st_mtime_ns,before.st_ino)==
         (after.st_size,after.st_mtime_ns,after.st_ino),'VALIDATION_INPUT_CHANGED')
    return result

def pinned(ref,root):
    need(isinstance(ref,dict) and {'Path','SHA256'}<=set(ref),'VALIDATION_REFERENCE_SCHEMA')
    path=bounded(ref['Path'],root)
    need(re.fullmatch('[0-9a-f]{64}',ref['SHA256']) is not None and
         reference(path)['SHA256']==ref['SHA256'],'VALIDATION_INPUT_HASH_CHANGED')
    return path

def rows(path):
    with Path(path).open(encoding='utf-8-sig',newline='')as stream:
        reader=csv.DictReader(stream);headers=reader.fieldnames;values=list(reader)
    need(headers and len(headers)==len(set(headers)) and
         all(None not in row and None not in row.values()for row in values),'OUTPUT_TABLE_SCHEMA')
    return headers,values

def verify_exact_roles(step,native,parent,job):
    """Bind every selected field to validated native tables without numeric conversion."""
    prefix='C'+job[1:];exact=step/'exact'
    need({p.name for p in exact.iterdir() if p.is_file()}=={r+'.csv'for r in ROLES},'EXACT_OUTPUT_ROLE_SET')
    hashes={'exact/'+r+'.csv':core.sha(exact/(r+'.csv'))for r in ROLES}
    schemas=read(PACKAGE/'results/weekday_schema.json')['roles']
    def check(role,source,label=None):
        headers,values=rows(source)
        known=set().union(*(set(v)for v in schemas[role]))
        variants=[v for v in schemas[role]if set(v)==set(headers)&known]
        need(len(variants)==1,'SELECTED_SOURCE_PROJECTION_SCHEMA')
        fields=list(variants[0])
        if label is not None:
            values=[row for row in values if row['TestRole']==label]
            need(len(values)==1,'SELECTED_JOINT_EXPORT_CHANGED')
        projected=[{field:row[field]for field in fields}for row in values]
        need(rows(exact/(role+'.csv'))==(fields,projected),'SELECTED_EXPORT_PROJECTION_CHANGED')
    for role in ROLES[:4]:
        check(role,native/'csv'/(prefix+'_'+role+'.csv'))
    for role,label in [('endpoint_joint','MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY'),
                       ('trajectory_joint','MONDAY_FRIDAY_TRAJECTORY_INTERACTION')]:
        check(role,native/'csv'/(prefix+'_joint.csv'),label)
    check('reference_profile',parent/'model_csv'/(job+'_profile.csv'))
    return hashes

def stage_bindings(step,runtime,context,corrected):
    stages=runtime['stages']
    expected=['native_initial','native_pass']if corrected else ['native_pass']
    need(isinstance(stages,list)and len(stages)==len(expected),'NATIVE_STAGE_COUNT')
    refs=[]
    for record,name in zip(stages,expected):
        directory=bounded(record['directory'],step)
        need(directory==step/name,'NATIVE_STAGE_DIRECTORY')
        for field,file in [('contextSHA256','context.json'),('executionSHA256','execution.json'),
                           ('programSHA256','analysis.sas'),('producerStatusSHA256','producer_status.json'),
                           ('completeMarkerSHA256','completed.txt')]:
            ref={'Path':str(directory/file),'SHA256':record[field]}
            pinned(ref,step);refs.append(ref)
        stage_context=read(directory/'context.json');execution=read(directory/'execution.json')
        need(execution.get('completed') is True and execution.get('contextHash')==canonical(stage_context)and
             execution.get('sourceCodeHash')==context['identity']['CodeHash']and
             stage_context.get('job')==context['job']and stage_context.get('identity')==context['identity']and
             stage_context.get('expected')==context['expected'],'NATIVE_STAGE_IDENTITY')
        need((directory/'completed.txt').read_text().strip()=='ANALYSIS_STEP_COMPLETE','NATIVE_COMPLETION_MARKER')
        status=read(directory/'producer_status.json')
        need(status.get('JobID')==context['job']['JobID'],'NATIVE_STAGE_STATUS_IDENTITY')
        need(stage_context.get('stage')==('CORRECTED'if corrected and name=='native_pass'else'INITIAL'),
             'NATIVE_STAGE_ROLE')
        if name=='native_initial':
            need(status.get('ProducerIntegrationPASS')!=1 and status.get('ReasonCode')==
                 'EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH'and record.get('nativeCompleteSHA256')is None and
                 not(directory/'native_complete.json').exists(),'NATIVE_INITIAL_FAILURE_SCOPE')
        else:
            need(status.get('ProducerIntegrationPASS')==1 and record.get('nativeCompleteSHA256'),
                 'NATIVE_FINAL_COMPLETION_REQUIRED')
            ref={'Path':str(directory/'native_complete.json'),'SHA256':record['nativeCompleteSHA256']}
            pinned(ref,step);refs.append(ref)
    return refs

def candidate_context(step,parent,case,selection,lineage_path):
    """Replay the retained-QR solution and check each native derivative."""
    import pyreadstat
    lineage_path=bounded(lineage_path,step);lineage_ref=reference(lineage_path);lineage=read(lineage_path)
    job=case['OriginalModelAndNewTargets']['JobID']
    need(lineage.get('Protocol')=='FIXED_COVARIANCE_MEAN_DERIVATIVE_V1' and
         lineage.get('JobID')==job and lineage.get('CandidateMeanID')==selection['CandidateMeanID'] and
         lineage.get('WorkingCovarianceChanged') is False and lineage.get('OriginalArchiveChanged') is False,
         'CANDIDATE_LINEAGE_SCOPE')
    inputs=lineage['ParentInputs']
    need(set(inputs)=={'basis','beta','params','global_factor','qr','score'},'CANDIDATE_INPUT_ROLES')
    paths={key:pinned(ref,parent if key in {'qr','score'}else step)for key,ref in inputs.items()}
    by_name={Path(ref['Path']).name.lower():ref for ref in case['Files']}
    for key,name in [('qr','c'+job[1:]+'_cs_qr.sas7bdat'),('score',job.lower()+'_score_design.sas7bdat')]:
        need(name in by_name and inputs[key]['SHA256']==by_name[name]['SHA256'] and
             paths[key]==Path(by_name[name]['Path']).resolve(),'CANDIDATE_PARENT_ARCHIVE_CHANGED')
    initial=read(step/'native_initial/producer_status.json')
    need(initial.get('JobID')==job and initial.get('ProducerIntegrationPASS')!=1 and
         initial.get('ReasonCode')=='EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH','CORRECTION_REQUIRES_BOUND_RESIDUAL_MISMATCH')
    def native(key,columns=None):
        frame,metadata=pyreadstat.read_sas7bdat(paths[key],usecols=columns)
        if columns is not None:need(metadata.column_names==columns,'CANDIDATE_RETAINED_COLUMNS')
        return frame
    frame=native('basis');ri,ci=frame['Parameter'].to_numpy(),frame['ActiveColumn'].to_numpy()
    need(len(ri)>0 and np.isfinite(ri).all() and np.isfinite(ci).all() and
         np.all(ri>=1) and np.all(ci>=1) and np.all(ri==np.floor(ri)) and np.all(ci==np.floor(ci)),
         'CANDIDATE_BASIS_KEYS')
    p,rank=int(ri.max()),int(ci.max())
    need(0<rank<=p<=200 and len(set(zip(ri,ci)))==p*rank,'CANDIDATE_BASIS_DIMENSIONS')
    E=np.full((p,rank),np.nan);E[ri.astype(int)-1,ci.astype(int)-1]=frame['Value']
    core.close(E.T@E,np.eye(rank),'CAPTURED_BASIS_ORTHONORMAL',rtol=0,atol=2e-9)
    frame=native('beta').sort_values('Parameter')
    need(np.array_equal(frame['Parameter'],np.arange(1,p+1)),'CANDIDATE_BETA_KEYS')
    beta=frame['Estimate'].to_numpy(dtype=float).reshape(p,1);old=core.original_loader(case)
    original=old(job+'_solution.csv');expected={}
    for effect,estimate in zip(original.c('Effect'),original.n('Estimate')):
        match=re.fullmatch(r'RBCX([1-9][0-9]*)',effect.strip(),re.I)
        need(match is not None,'ORIGINAL_BETA_EFFECTS')
        index=int(match[1]);need(1<=index<=p and index not in expected,'ORIGINAL_BETA_EFFECT_KEYS')
        expected[index]=estimate
    need(len(expected)==p,'ORIGINAL_BETA_EFFECTS')
    need(candidate.bitwise_equal(beta[:,0],[expected[i+1]for i in range(p)]),'CAPTURED_ORIGINAL_BETA_CHANGED')
    params=native('params')
    need(len(params)==1 and params['FittedRank'].iloc[0]==rank and params['ParameterCount'].iloc[0]==p,
         'CANDIDATE_FIXED_RANK')
    tau,sigma=float(params['Tau2'].iloc[0]),float(params['Sigma2'].iloc[0])
    covariance=old(job+'_covparms.csv');covariance=dict(zip(covariance.c('CovParm'),covariance.n('Estimate')))
    need(set(covariance)=={'Intercept','Residual'} and tau==covariance['Intercept'] and
         sigma==covariance['Residual'] and tau>=0 and sigma>0,'CANDIDATE_FIXED_VARIANCES')
    columns=['Cluster','Row','NObs','K0']+['RBCX'+str(i+1)for i in range(p)]+['Cross']
    qr=native('qr',columns).to_numpy(dtype=float,copy=False)
    need(len(qr)>0 and len(qr)%(p+2)==0 and np.isfinite(qr).all(),'CANDIDATE_QR_SCHEMA')
    def blocks():
        for i in range(len(qr)//(p+2)):
            block=qr[i*(p+2):(i+1)*(p+2)];nobs=block[0,2]
            need(np.all(block[:,0]==i+1) and np.array_equal(block[:,1],np.arange(1,p+3)) and
                 np.all(block[:,2]==nobs) and nobs>=1 and nobs==np.floor(nobs),'CANDIDATE_QR_BLOCK_KEYS')
            q=block[:,[3]]
            need(abs(float((q.T@q).item())-nobs)<=128*np.finfo(float).eps*(p+2)*nobs,
                 'CANDIDATE_QR_INTERCEPT_COUNT')
            yield q,block[:,4:4+p],block[:,[-1]]
    replay=candidate.reference_from_blocks(blocks(),E,beta,tau,sigma);tiny=np.finfo(float).tiny
    need(np.all(np.abs(replay['ResponseClosureResidual'])<=2e-8*np.maximum(replay['ResponseClosureScale'],tiny)),
         'FIXED_RESPONSE_CLOSURE')
    frame=native('global_factor');ri,ci=frame['Row'].to_numpy(),frame['Column'].to_numpy()
    need(len(frame)==p*p and len(set(zip(ri,ci)))==p*p and
         np.array_equal(np.unique(ri),np.arange(1,p+1)) and np.array_equal(np.unique(ci),np.arange(1,p+1)),
         'GLOBAL_FACTOR_KEYS')
    global_factor=np.full((p,p),np.nan);global_factor[ri.astype(int)-1,ci.astype(int)-1]=frame['Value']
    qgram=replay['TriangularDesign'].T@replay['TriangularDesign'];G=global_factor@E;ggram=G.T@G
    need(np.linalg.norm(qgram-ggram)<=2e-8*max(np.linalg.norm(qgram),np.linalg.norm(ggram),tiny),
         'INDEPENDENT_RETAINED_DESIGN_GRAM')
    selected,applied=candidate.candidate_arrays(candidate,beta,E,replay['DeltaActive'],lineage)
    del qr,frame
    ctx={'Beta':selected,'OriginalBeta':beta.reshape(-1),'AppliedChange':applied,
         'CandidateMeanID':lineage['CandidateMeanID']}
    def member(folder,name):
        found=[p for p in folder.iterdir()if p.is_file()and p.name.lower()==name.lower()]
        need(len(found)==1,'CANDIDATE_NATIVE_MEMBER');return reference(found[0])
    folder=lineage_path.parent;prefix='C'+job[1:]
    exchange={'cs_qr':member(folder/'saved',prefix+'_cs_qr.sas7bdat'),
              'cs_solution':member(folder/'saved',prefix+'_cs_solution.sas7bdat'),
              'model_solution':member(folder/'models',job+'_solution.sas7bdat'),
              'model_trajectory':member(folder/'models',job+'_trajectory.sas7bdat')}
    derivatives=candidate.verify_native_derivatives({'ExchangeFiles':exchange},{'Cases':[case]},core,ctx,candidate,job)
    for key,ref in inputs.items():pinned(ref,parent if key in {'qr','score'}else step)
    pinned(lineage_ref,step)
    for ref in exchange.values():pinned(ref,step)
    ctx['Evidence']={'lineage':lineage_ref,'inputs':inputs,'nativeOutputs':exchange,
                     'independentRetainedQRReplay':True,'nativeDerivatives':derivatives}
    ctx['selectedMeanEvidence']={'CandidateMeanID':lineage['CandidateMeanID'],
        'solutionSHA256':exchange['model_solution']['SHA256'],'trajectorySHA256':exchange['model_trajectory']['SHA256']}
    return ctx

def validate_weekday_step(step,context):
    """Validate a declared weekday selection without executing SAS."""
    step=Path(step).resolve()
    need(context.get('task')=='WEEKDAY' and read(step/'context.json')==context,'WEEKDAY_CONTEXT')
    execution=read(step/'execution.json')
    need(execution.get('completed') is True and execution.get('contextHash')==canonical(context),'WEEKDAY_EXECUTION_BINDING')
    runtime=execution.get('result',context);job=context['job']['JobID']
    need(re.fullmatch(r'M[0-9]{4}',job) is not None and context['job']['FactorName']=='wdy_donation','WEEKDAY_MODEL_IDENTITY')
    plan=context['plan']
    need(plan['Method'] in METHOD_MAP and plan['JobID']==job and
         all(plan[k]==context['job'][k]for k in ['FitId','PopulationId','Model','VitalCode']) and
         plan['ReferenceCategory']=='2' and plan['ReportedCategories']=='2 3 4 5 6' and plan['HolmFamilySize']=='10',
         'WEEKDAY_ANALYSIS_PLAN')
    parent=(step.parent.parent/'models'/job).resolve()
    need(parent.is_dir() and parent!=step and not parent.is_relative_to(step),'ORIGINAL_PARENT_DIRECTORY')
    for key,file in [('contextSHA256','context.json'),('executionSHA256','execution.json'),
                     ('workingValidationSHA256','working_validation.json')]:
        need(core.sha(parent/file)==context['parent'][key],'ORIGINAL_PARENT_RECEIPT_CHANGED')
    working=read(parent/'working_validation.json')
    need(working.get('validation',{}).get('status')=='VALIDATED' and
         working['validation'].get('scope')=='WORKING_MODEL_ONLY' and
         working.get('contextHash')==canonical(read(parent/'context.json')),'ORIGINAL_WORKING_MODEL_NOT_VALIDATED')
    refs=runtime['parentFiles'];need(isinstance(refs,list) and refs,'PARENT_FILE_BINDINGS_REQUIRED')
    for ref in refs:pinned(ref,parent)
    names=[Path(x['Path']).name.lower()for x in refs if Path(x['Path']).suffix.lower()=='.csv']
    need(len(names)==len(set(names)),'AMBIGUOUS_PARENT_CSV_ROLE')
    native=bounded(runtime['nativeDirectory'],step);source=core.sha(PACKAGE/'sas/07_weekday.sas')
    need(runtime['nativeProducerSHA256']==source,'WEEKDAY_SOURCE_CHANGED')
    selection=context['selection'];method=METHOD_MAP.get(runtime['appliedBranch'])
    need(method in METHODS and method==METHOD_MAP[plan['Method']],'WEEKDAY_BRANCH_NOT_DECLARED')
    corrected=method=='FIXED_COVARIANCE_CORRECTION'
    stage_refs=stage_bindings(step,runtime,context,corrected)
    need(selection['InferenceScope']=='MONDAY_FRIDAY' and
         selection['ScalarDFMethod']=='CONTRAST_SATTERTHWAITE' and selection['JointDFMethod']=='HTZ' and
         selection['TargetSetID']==job+'_MONDAY_FRIDAY_V1_eefab4e58bd5' and
         selection['HolmFamilyID']==job+'_HOLM10_V1_801e3333cc8c' and
         selection['MeanSolutionKind']==('FIXED_COVARIANCE_GLS_RECOVERY'if corrected else'ORIGINAL_FIT') and
         selection['OriginalMeanOriginIsParentProvenanceOnly']==int(corrected) and
         ((selection['CandidateMeanID']=='NONE') != corrected),'SELECTED_MEAN_AND_INFERENCE')
    scope={'full_cohort':'FULL_COHORT_MODEL_INFERENCE','development_sample':'LOCAL_SAMPLE_MODEL_INFERENCE'}[context['expected']['CohortMode']]
    case={'OriginalModelAndNewTargets':context['job'],'Files':refs,'Scope':scope}
    getold=core.original_loader(case);categories=getold(job+'_cat_availability.csv')
    codes,indices=categories.n('CategoryCode'),categories.n('CategoryIndex')
    finite=np.isfinite(indices)
    need(np.isfinite(codes).all() and np.all(codes==np.floor(codes)) and len(set(codes))==len(codes) and
         len(set(indices[finite]))==int(finite.sum()) and np.all(indices[finite]>=1) and
         np.all(indices[finite]==np.floor(indices[finite])) and set(range(2,7))<=set(codes[finite]),
         'ORIGINAL_WEEKDAY_CATEGORY_MAP')
    case['OriginalCategoryMapping']=[{'CategoryCode':int(c),'CategoryIndex':int(i)}for c,i in zip(codes[finite],indices[finite])]
    hashes=verify_exact_roles(step,native,parent,job)
    native_refs=stage_refs+[reference(p)for p in sorted((native/'csv').glob('*.csv'))]
    native_refs += [reference(native/n)for n in ('producer_status.json','native_complete.json')]
    selected_mean=None
    with threadpool_limits(limits=1):
        if method=='ACCEPTED_REUSE':
            accepted=read(parent/'validation.json')
            need(accepted.get('contextHash')==working['contextHash'] and
                 accepted.get('validation',{}).get('status')=='VALIDATED','ACCEPTED_PARENT_INFERENCE_REQUIRED')
            old_hashes=accepted['validation']['inputHashes']['robust']
            for ref in refs:
                p=Path(ref['Path'])
                if p.parent==parent/'inference_csv':
                    need(old_hashes.get(p.name)==ref['SHA256'],'ACCEPTED_INFERENCE_INPUT_CHANGED')
            original=getold('C'+job[1:]+'_certificate_context.csv').c('ConstructionSourceSHA256')
            need(len(original)==1 and original[0]==runtime['originalConstructionSHA256'],'ORIGINAL_COVARIANCE_SOURCE_CHANGED')
            proof={'Status':'ORIGINAL_ACCEPTED_FULL_CR2_PROOF_BOUND','ProofKind':'PORTABLE_MODEL_VALIDATION',
                   'References':{'IndependentValidation':reference(parent/'validation.json')},
                   'ConstructionSourceSHA256':original[0]}
            result=core.validate_reuse(native,case,original[0],accepted_proof=proof)
        else:
            if corrected:
                need(plan.get('CorrectionEligibility')=='RECORDED_RESIDUAL_MISMATCH','CORRECTION_ELIGIBILITY')
                selected_mean=candidate_context(step,parent,case,selection,runtime['candidateLineage'])
            result=core.validate_saved(native,case,source,candidate_context=selected_mean)
    need(result['Status']=='PASS' and set(result['RoleDispositions'])==set(ROLES)-{'reference_profile'},'SIX_SCIENTIFIC_ROLES_REQUIRED')
    if corrected:need(result['CompleteSupportedCompanion'] is True,'COMPLETE_SIX_ROLE_CANDIDATE_REQUIRED')
    for ref in refs:pinned(ref,parent)
    for ref in native_refs:pinned(ref,step)
    need(hashes==verify_exact_roles(step,native,parent,job),'SELECTED_OUTPUT_CHANGED_DURING_VALIDATION')
    need(read(step/'context.json')==context and read(step/'execution.json')==execution,'WEEKDAY_CONTEXT_CHANGED_DURING_VALIDATION')
    for ref in native_refs:
        hashes[Path(ref['Path']).resolve().relative_to(step).as_posix()]=ref['SHA256']
    if selected_mean is not None:
        evidence=selected_mean['Evidence']
        for ref in [evidence['lineage'],*evidence['inputs'].values(),*evidence['nativeOutputs'].values()]:
            path=Path(ref['Path']).resolve()
            if path.is_relative_to(step):hashes[path.relative_to(step).as_posix()]=ref['SHA256']
    result={'status':'VALIDATED','scope':'MONDAY_FRIDAY','inputHashes':hashes,'details':result,
            'method':plan['Method'],'parentFiles':refs,'scientificInputFiles':native_refs,'nativeProducerSHA256':source,
            'sixRolesValidated':True,'originalInferenceStatusChanged':False}
    if selected_mean is not None:
        result['selectedMeanEvidence']=selected_mean['selectedMeanEvidence']
        result['candidateValidation']=selected_mean['Evidence']
    return result