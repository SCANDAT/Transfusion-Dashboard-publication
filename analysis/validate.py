"""Independently validate scientific outputs; incomplete inference stays unavailable."""
from __future__ import annotations
import hashlib,json,sys,stat
from pathlib import Path
PACKAGE=Path(__file__).resolve().parent
sys.path.insert(0,str(PACKAGE/'python'))
from file_utils import digest,write_once,safe_path
import scalar_availability as scalar
import inference_availability as inference

def require(ok,code):
    if not ok:raise ValueError(code)

def robust_context(expected,identity,science):
    context=dict(expected,DFMethod='SATTERTHWAITE',SubjectKeySource='PersonKey',SubjectAlias='PatientID',DesignIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH',ProfileIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH',InferenceStatus='CR2_CHECKS_PASSED',WorkingDFMethod='RESIDUAL',WorkingInferenceStatus='MODEL_BASED_CANDIDATE',Scope={'development_sample':'LOCAL_SAMPLE_MODEL_INFERENCE','full_cohort':'FULL_COHORT_MODEL_INFERENCE'}[expected['CohortMode']],CovarianceMethod='GLS_WHITENED_CR2',ScalarDFMethod='CONTRAST_SATTERTHWAITE',JointDFMethod='HTZ',WorkingTarget='FROZEN_REML_RANDOM_INTERCEPT_IID',CR2Protocol=scalar.cr2_protocol(science['ScalarAvailabilityPolicy']),CR2ArchiveID='C'+expected['JobID'][1:],BindingVersion=3,WorkingBindingVersion=1,CalibrationDomain='FIXED_PREDECLARED_TARGET_SPAN',StructuralCertificate='RAW_LITERAL_SUPPORT_V1',TargetCalibrationVerified=1,AllCoefficientsCalibrated=0,ConstructionSourceSHA256=identity['CertificateCodeHash'])
    if science['ScalarAvailabilityPolicy']!=scalar.STRICT:context[scalar.CONFIG_KEY]=science['ScalarAvailabilityPolicy']
    return context

def archive_hashes(folder):
    return {p.name:__import__('run').file_hash(p) for p in sorted(folder.glob('*.csv'))}


def model_archive_hashes(folder,started_ns):
    """Bind fresh regular CSV exports using the original size and timestamp limits."""
    result={}
    for member in sorted(folder.glob('*.csv')):
        path=safe_path(member)
        require(path.stat().st_mtime_ns>=started_ns,'STALE_EXCHANGE')
        before=path.stat()
        require(stat.S_ISREG(before.st_mode),'REGULAR_FILE_REQUIRED')
        require(path.suffix.lower()=='.csv','BINARY_CONTENT_READ_FORBIDDEN')
        require(before.st_size<=512*2**20,'FILE_SIZE_REJECTED')
        identity=lambda info:(info.st_size,info.st_mtime_ns,info.st_ino,info.st_dev)
        result[path.name]=__import__('run').file_hash(path)
        after=safe_path(path).stat()
        require(stat.S_ISREG(after.st_mode) and identity(after)==identity(before),'FILE_CHANGED')
    return result

def validate_working_step(step, expected_preparation=None):
    """Validate retained mean-fit outputs without accepting their old inference.

    An inference failure can leave a complete working-model archive. Its own
    execution status is preserved; this receipt covers the working fit only.
    """
    from run import read_json,expected_working,jobs,file_hash
    import validate_model_archive as working
    step=safe_path(step)
    context=read_json(step/'context.json');execution=read_json(step/'execution.json')
    require(context['task']=='MODEL' and context['job'] in jobs(),'WORKING_PARENT_MODEL_REQUIRED')
    require(execution.get('contextHash')==digest(context),'WORKING_PARENT_CONTEXT_CHANGED')
    require(execution.get('sourceCodeHash')==context['identity']['CodeHash'],'WORKING_PARENT_SOURCE_CHANGED')
    require(context['expected']==expected_working(context['identity'],context['job']),'WORKING_PARENT_DEFINITION_CHANGED')
    if expected_preparation is not None:
        for field in ('RunId','AnalysisSpecId','CohortMode','InputSnapshotId','PreparationReceiptHash'):
            require(context['identity'].get(field)==expected_preparation.get(field),'WORKING_PARENT_PREPARATION_CHANGED')
    before=model_archive_hashes(step/'model_csv',execution['started_ns'])
    binding={'contextHash':digest(context),'contextSHA256':file_hash(step/'context.json'),
             'executionSHA256':file_hash(step/'execution.json'),
             'meanFitSHA256':context['expected']['CodeHash']}
    target=step/'working_validation.json'
    if target.exists():
        prior=read_json(target)
        require(all(prior.get(k)==v for k,v in binding.items()),'WORKING_RECEIPT_BINDING_CHANGED')
        result=prior.get('validation',{})
        require(result.get('status')=='VALIDATED' and result.get('scope')=='WORKING_MODEL_ONLY'
                and result.get('inputHashes')==before and result.get('details',{}).get('status')=='VALIDATED',
                'WORKING_RECEIPT_INVALID')
        return prior
    report=None
    if (step/'validation.json').is_file():
        existing=read_json(step/'validation.json')
        if existing.get('contextHash')==digest(context):
            result=existing.get('validation',{})
            candidate=result.get('workingValidation')
            if (result.get('status')=='VALIDATED' and isinstance(candidate,dict)
                    and candidate.get('status')=='VALIDATED'
                    and result.get('inputHashes',{}).get('working')==before):
                report=candidate
    reused=report is not None
    if report is None:
        report=working.validate(step/'model_csv',context['job']['JobID'],context['expected'])
    require(report.get('status')=='VALIDATED','WORKING_VALIDATION_FAILED')
    require(before==model_archive_hashes(step/'model_csv',execution['started_ns']),
            'WORKING_ARCHIVE_CHANGED_DURING_VALIDATION')
    receipt={**binding,'validation':{'status':'VALIDATED','scope':'WORKING_MODEL_ONLY',
             'details':report,'inputHashes':before,'reusedExistingWorkingValidation':reused}}
    write_once(target,receipt)
    return receipt


def validate_model(step,context,started_ns):
    import validate_model_archive as working
    import fit_status_contract as status
    import validate_cr2_white_archive as robust
    import derive_model_trajectory as trajectory
    import compare_same_fit_inference as samefit
    import validate_inference_unavailable as unavailable
    expected=context['expected'];job=expected['JobID'];prefix='C'+job[1:]
    science=context['scientificSettings'];identity=context['identity']
    folder=step/'model_csv';cr2=step/'inference_csv'
    before={'working':model_archive_hashes(folder,started_ns),'robust':model_archive_hashes(cr2,started_ns)}
    present=set(before['working'])
    unavailable_names={job+'_'+r+'.csv' for r in (*status.UNAVAILABLE_ROLES,'archive_manifest')}
    if present==unavailable_names:
        report=status.validate_unavailable(folder,job,expected)
        require(report.get('status')=='EXPECTED_UNAVAILABLE_VALIDATED' and report['ReasonCode'] in status.UNAVAILABLE_REASONS,'PREFIT_UNAVAILABLE_NOT_SUBSTANTIATED')
        require(not any(cr2.iterdir()) and not any((step/'inference_tables').iterdir()),'UNAVAILABLE_HAS_INFERENCE_OUTPUT')
        result={'status':'EXPECTED_UNAVAILABLE_VALIDATED','reason':report['ReasonCode'],'fitAttempted':False}
    else:
        require(present=={job+'_'+r+'.csv' for r in (*working.ROLES,'archive_manifest')},'WORKING_FILE_SET_INVALID')
        report=working.validate(folder,job,expected);require(report.get('status')=='VALIDATED','WORKING_VALIDATION_FAILED')
        require(trajectory._prepare(folder,job,expected) is not None,'WORKING_CHANGE_RECONSTRUCTION_FAILED')
        policy=science['StructuralInferencePolicy'];scalar_policy=science['ScalarAvailabilityPolicy']
        if set(before['robust'])==inference.file_names(prefix):
            require(policy==inference.SPCU_V1,'STRUCTURAL_UNAVAILABLE_POLICY_NOT_SELECTED')
            answer=unavailable.validate_archive(cr2,prefix,dict(expected,**{inference.CONFIG_KEY:policy}),working_folder=folder,job=job,working_report=report,export_started_ns=started_ns)
            require(answer.get('status')==unavailable.VALIDATED and answer.get('reason_code')==inference.KERNEL_REASON,'STRUCTURAL_UNAVAILABLE_NOT_SUBSTANTIATED')
            result={'status':inference.RECEIPT_STATUS,'reason':inference.KERNEL_REASON,'fitAttempted':True,'details':answer}
        else:
            guard=None
            if policy==inference.SPCU_V1:
                evidence=unavailable.working_single_person_codes(folder,job,expected,working_report=report)
                require(evidence.get('WorkingArchiveContentDigest')==report['ArchiveContentDigest'],'WORKING_BINDING_CHANGED')
                guard=inference.supported_guard(evidence['SinglePersonCategoryCodes'])
            # None selects the unchanged serial 80-digit directed-decimal engine.
            answer=robust.validate_archive(cr2,prefix,robust_context(expected,identity,science),export_started_ns=started_ns,decimal_replay=None)
            require(answer.get('status')=='VALIDATED' and answer.get('reason_code')=='PASS','ROBUST_VALIDATION_FAILED')
            scalar.require_receipt_matches(scalar_policy,answer)
            comparison=samefit.compare(folder,job,cr2,prefix,expected,scalar_policy=scalar_policy)
            require(comparison.get('status')=='SAME_FIT_COMPARISON_PASSED','SAME_FIT_CHECK_FAILED')
            result={'status':'VALIDATED','workingValidation':report,'inferenceValidation':answer,'sameFitComparison':comparison,'supportGuard':guard}
    require(before=={'working':model_archive_hashes(folder,started_ns),'robust':model_archive_hashes(cr2,started_ns)},'ARCHIVE_CHANGED_DURING_VALIDATION')
    result['inputHashes']=before
    return result


def preparation_binding(step,context,science):
    """Require this step to belong to the unchanged preparation in its output root."""
    from run import package_hash,prepared_metadata
    kind=context['task'];step=safe_path(step)
    if kind in {'MODEL','REPORT'}:
        require(step.parent.name=={'MODEL':'models','REPORT':'reports'}[kind],'ANALYSIS_STEP_LOCATION_INVALID')
        output=step.parent.parent
    elif kind=='LOESS':
        require(step.name=='loess','ANALYSIS_STEP_LOCATION_INVALID')
        output=step.parent
    else:raise ValueError('UNSUPPORTED_VALIDATION_STEP')
    receipt_path=safe_path(output/'preparation.json')
    raw=receipt_path.read_bytes();prepared=json.loads(raw.decode('utf-8-sig'))
    receipt_hash=hashlib.sha256(raw).hexdigest()
    identity=prepared['identity']
    require(context['scientificSettings']==science and identity['CodeHash']==package_hash() and identity['ConfigHash']==digest(science),'SCIENTIFIC_CODE_OR_SETTINGS_CHANGED')
    require(context['identity']=={**identity,'PreparationReceiptHash':receipt_hash},'PREPARATION_IDENTITY_MISMATCH')
    current_metadata=prepared_metadata(output)
    require(bool(prepared['preparedMetadata']) and prepared['preparedMetadata']==current_metadata,'PREPARED_TABLES_CHANGED')
    return {'preparationSha256':receipt_hash,'preparedMetadata':current_metadata}

def validate_step(step):
    from run import read_json,expected_working,jobs
    context=read_json(step/'context.json');execution=read_json(step/'execution.json')
    science=read_json(PACKAGE/'scientific_settings.json')
    require(execution.get('completed') is True,'SAS_STEP_NOT_COMPLETED')
    require(execution.get('contextHash')==digest(context),'EXECUTION_CONTEXT_CHANGED')
    preparation=preparation_binding(step,context,science)
    kind=context['task'];expected=context['expected']
    if kind=='MODEL':
        require(context['job'] in jobs() and expected==expected_working(context['identity'],context['job']),'MODEL_DEFINITION_MISMATCH')
        result=validate_model(step,context,execution['started_ns'])
        require(preparation_binding(step,context,science)==preparation,'PREPARATION_CHANGED_DURING_VALIDATION')
        return result
    if kind=='REPORT':
        import validate_aggregate_reports as reports
        answer=reports.validate_archive(step/'csv',expected,export_started_ns=execution['started_ns'])
        require(answer.get('status')=='AGGREGATE_ARCHIVE_VALIDATED','REPORT_VALIDATION_FAILED')
    elif kind=='LOESS':
        import validate_loess_report as loess
        answer=loess.validate_archive(step/'csv',expected,export_started_ns=execution['started_ns'])
        require(answer.get('status')=='LOESS_ARCHIVE_VALIDATED','LOESS_VALIDATION_FAILED')
    else:raise ValueError('UNSUPPORTED_VALIDATION_STEP')
    validated_hashes={name:binding['sha256'] for name,binding in answer['ExpectedFiles'].items()}
    require(archive_hashes(step/'csv')==validated_hashes,'ARCHIVE_CHANGED_AFTER_VALIDATION')
    require(preparation_binding(step,context,science)==preparation,'PREPARATION_CHANGED_DURING_VALIDATION')
    return {'status':'VALIDATED','details':answer,'inputHashes':validated_hashes}

def validate_directory(output, model_ids=None):
    from analysis_steps import select_steps
    steps=select_steps(output,model_ids)
    require(bool(steps),'NO_ANALYSIS_OUTPUTS_TO_VALIDATE')
    failures=0
    for step in steps:
        try:
            result=validate_step(step)
            payload={'validation':result,'contextHash':digest(json.loads((step/'context.json').read_text(encoding='utf-8-sig')))}
            destination=step/'validation.json'
            if destination.exists():require(json.loads(destination.read_text())==payload,'EXISTING_VALIDATION_DIFFERS')
            else:write_once(destination,payload)
            print(step.name+': '+result['status'],flush=True)
        except Exception as error:
            failures+=1
            diagnostic={'status':'UNRESOLVED','exceptionType':type(error).__name__,'detail':str(error)}
            error_path=step/'validation_error.json'
            if not error_path.exists():write_once(error_path,diagnostic)
            # Report fixed status only; full diagnostic records remain local.
            print(step.name+': UNRESOLVED ('+type(error).__name__+').',flush=True)
    require(failures==0,'One or more analyses remain unresolved. They must not be treated as accepted results.')
