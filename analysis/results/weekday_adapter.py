"""Select validated Monday-Friday aggregate results without statistical estimation."""
from __future__ import annotations
import csv,io,itertools,json,math
from pathlib import Path
import release_format as f
HERE=Path(__file__).resolve().parent
SCHEMAS=json.loads((HERE/'weekday_schema.json').read_text(encoding='utf-8'))['roles']
WEEKDAYS={2,3,4,5,6}
SIX=('levels','changes','within','pairwise','endpoint_joint','trajectory_joint')
PUBLIC_ROLES=SIX+('reference_profile',)
CANDIDATE_ROLES=('candidate_input_solution','candidate_input_trajectory')
PARENT_FIELDS=('RunId','AnalysisSpecId','CohortMode','PopulationId','FitId','InputSnapshotId','CodeHash','ConfigHash','DesignId','ProfileId','JobID','ProfileIdentityKind')
SELECTION_FIELDS=('InferenceScope','TargetSetID','HolmFamilyID','MeanSolutionKind','CandidateMeanID','OriginalMeanOriginIsParentProvenanceOnly','ScalarDFMethod','JointDFMethod')
SELECTION_SCHEMA='transfusion-analysis/weekday-selection-v1'
# This protocol describes the frontend table contract, not the native receipt format.
PROTOCOL='MONDAY_FRIDAY_IMMUTABLE_COMPANION_BUNDLE_V1'
need=f.require
sha=f.digest

def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode('ascii')

def exact(value,fields,code):
    need(isinstance(value,dict) and set(value)==set(fields),code)
def pack(header,rows):
    need(bool(rows),'EMPTY_COMPANION_ROLE')
    context={field:rows[0][field] for field in header if all(type(row[field]) is type(rows[0][field]) and row[field]==rows[0][field] and (not isinstance(row[field],float) or row[field]!=0 or math.copysign(1,row[field])==math.copysign(1,rows[0][field])) for row in rows)}
    cols=[field for field in header if field not in context]
    return {'context':context,'columns':cols,'rows':[[row[k] for k in cols] for row in rows]}

def close(a,b):
    return a is not None and b is not None and math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-10)

def check_role_values(roles,m):
    for role in ('levels','changes'):
        rows=roles[role][1]
        need(len(rows)==7205,'WEEKDAY_TRAJECTORY_COUNT')
        coords={(r['CategoryCodeA'],r['TimeFromTransfusion']) for r in rows}
        need(coords==set(itertools.product(WEEKDAYS,range(-720,721))),'WEEKDAY_TRAJECTORY_GRID')
        for row in rows:
            need(row['BaselineMinute']==-60,'BASELINE_MISMATCH')
            if row['NumericStatus']=='BASELINE_ZERO':
                need(role=='changes' and row['TimeFromTransfusion']==-60 and row['ContrastStatus']==2,'BASELINE_ZERO_LOCATION')
                need(all(row[k]==0 for k in ('Estimate','StdErr','Variance','Lower','Upper')),'BASELINE_ZERO_VALUES')
            else:
                need(row['NumericStatus']=='COMPUTED' and row['ContrastStatus']==0,'UNAVAILABLE_COMPANION_TRAJECTORY')
            need(row['Lower']<=row['Estimate']<=row['Upper'],'TRAJECTORY_INTERVAL_ORDER')
    within=roles['within'][1];pairwise=roles['pairwise'][1]
    need(len(within)==5 and {r['CategoryCodeA'] for r in within}==WEEKDAYS,'WEEKDAY_WITHIN_SCOPE')
    expected_pairs=set(itertools.combinations(sorted(WEEKDAYS),2))
    need(len(pairwise)==10 and {(r['CategoryCodeA'],r['CategoryCodeB']) for r in pairwise}==expected_pairs,'WEEKDAY_HOLM10_UNIVERSE')
    need({r['Rank'] for r in pairwise}==set(range(1,11)),'WEEKDAY_PAIR_RANKS')
    endpoint={r['CategoryCodeA']:r for r in roles['changes'][1] if r['TimeFromTransfusion']==60}
    within_by={r['CategoryCodeA']:r for r in within}
    for row in within+pairwise:
        need(row['BaselineMinute']==-60 and row['EndpointMinute']==60 and row['NumericStatus']=='COMPUTED' and row['ContrastStatus']==0,'WEEKDAY_ENDPOINT_SCOPE')
        need(row['Lower']<=row['Estimate']<=row['Upper'] and row['StdErr']>0 and row['DF']>0,'WEEKDAY_ENDPOINT_INTERVAL')
    for row in within:
        need(all(close(row[k],endpoint[row['CategoryCodeA']][k]) for k in ('Estimate','StdErr','Lower','Upper','DF')),'WITHIN_CURVE_COHERENCE')
    for row in pairwise:
        need(row['FamilyID']==m['Model']['HolmFamilyID'] and row['PAdjustment']=='Holm within amended fixed family10','WEEKDAY_FAMILY_ID')
        need(0<=row['PValue']<=row['PValue_Holm']<=1 and row['PValue']==row['Probt'],'WEEKDAY_PAIR_P_VALUES')
        need(close(row['Estimate'],within_by[row['CategoryCodeA']]['Estimate']-within_by[row['CategoryCodeB']]['Estimate']),'PAIR_WITHIN_COHERENCE')
    for role,label,index in (('endpoint_joint','MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY',1),('trajectory_joint','MONDAY_FRIDAY_TRAJECTORY_INTERACTION',2)):
        rows=roles[role][1]
        need(len(rows)==1 and rows[0]['TestRole']==label and rows[0]['TestIndex']==index,'WEEKDAY_JOINT_TARGET')
        row=rows[0]
        need(row['NumericStatus']=='COMPUTED' and row['JointStatus']==0 and row['DF1']>0 and row['DF2']>0 and 0<=row['ProbF']<=1,'WEEKDAY_JOINT_VALUES')

def table(n,release_id,key,role,parts,context):
    header,rows,digest=parts
    merged=[]
    for row in rows:
        need(all(k not in row or row[k]==v for k,v in context.items()),'COMPANION_CONTEXT_COLLISION')
        merged.append({**context,**row})
    final_header=list(context)+[k for k in header if k not in context]
    return {'schemaVersion':n.TABLE_SCHEMA,'releaseId':release_id,'key':key,'role':role,'sourceSha256':digest,**pack(final_header,merged)}

def profile_table(n,release_id,key,m,parent,parts):
    header,rows,digest=parts;need(len(rows)==1,'PROFILE_COUNT')
    row=rows[0]
    need(all(k not in row or row[k]==parent[k] for k in PARENT_FIELDS),'PROFILE_PARENT_IDENTITY')
    context={k:parent[k] for k in PARENT_FIELDS}
    context.update(row)
    context.update(SelectedAttemptId=m['OriginalMeanOrigin']['AttemptId'],Model=key['model'],FactorName='wdy_donation',VitalCode=key['outcome'],
        ReferenceProfileStatus='AVAILABLE',ConstructionId='BOUND_COMPANION_PROFILE_V1',SourceProfileSHA256=digest)
    return {'schemaVersion':n.PROFILE_TABLE_SCHEMA,'releaseId':release_id,'key':key,'profileId':context['ProfileId'],'sourceSha256':digest,'context':context,'columns':[],'rows':[[]]}

def check_selection(selection):
    exact(selection,SELECTION_FIELDS,'WEEKDAY_SELECTION_FIELDS')
    need(selection['InferenceScope']=='MONDAY_FRIDAY' and selection['ScalarDFMethod']=='CONTRAST_SATTERTHWAITE' and selection['JointDFMethod']=='HTZ','WEEKDAY_METHOD_CHANGED')
    for key in ('TargetSetID','HolmFamilyID','CandidateMeanID'):
        need(isinstance(selection[key],str) and f.TOKEN.fullmatch(selection[key]),'WEEKDAY_SELECTION_IDENTIFIER')
    corrected=selection['MeanSolutionKind']=='FIXED_COVARIANCE_GLS_RECOVERY'
    need(corrected or selection['MeanSolutionKind']=='ORIGINAL_FIT','WEEKDAY_MEAN_KIND')
    need(type(selection['OriginalMeanOriginIsParentProvenanceOnly']) is int and selection['OriginalMeanOriginIsParentProvenanceOnly']==int(corrected),'WEEKDAY_PARENT_SEMANTICS')
    need((selection['CandidateMeanID']!='NONE')==corrected,'WEEKDAY_CANDIDATE_PAIRING')
    return corrected

class Weekdays:
    def __init__(self,results):
        self.results=results
        expected={job for job,plan in results.plans.items() if plan['FactorName']=='wdy_donation'}
        rows=results.index.get('weekdays')
        if rows is None:
            # Without a weekday selection, the Monday–Friday contrasts remain pending.
            rows=[{'JobID':job,'state':'pending','reasonCode':'AWAITING_MONDAY_FRIDAY_SELECTION'} for job in sorted(expected)]
        need(isinstance(rows,list) and len(rows)==42,'WEEKDAY_42_STATES_REQUIRED')
        self.entries={}
        for entry in rows:
            need(isinstance(entry,dict) and entry.get('JobID') in expected and entry['JobID'] not in self.entries,'WEEKDAY_SELECTION_DUPLICATE')
            if entry.get('state')=='accepted':
                exact(entry,('JobID','state','directory','selectionSHA256'),'WEEKDAY_ENTRY_FIELDS')
                need(entry['directory']=='weekdays/'+entry['JobID'],'WEEKDAY_DIRECTORY')
                need(isinstance(entry['selectionSHA256'],str) and f.HEX.fullmatch(entry['selectionSHA256']),'WEEKDAY_ENTRY_HASH')
            else:
                exact(entry,('JobID','state','reasonCode'),'WEEKDAY_STATUS_FIELDS')
                need(entry['state'] in {'pending','failed','inference_unavailable'} and isinstance(entry['reasonCode'],str) and f.REASON.fullmatch(entry['reasonCode']),'WEEKDAY_STATE')
            self.entries[entry['JobID']]=entry
        need(set(self.entries)==expected,'WEEKDAY_42_STATES_REQUIRED')
    def selection(self,job):
        return Selection(self.results,self.entries[job])

class Selection:
    def __init__(self,results,entry):
        self.results,self.entry=results,entry
        job,directory=entry['JobID'],entry['directory']; self.plan=results.plans[job]
        receipt=results.bound(directory+'/selection.json',entry['selectionSHA256'],json_file=True)
        exact(receipt,('schemaVersion','JobID','contextSHA256','executionSHA256','validationSHA256','conversionSHA256'),'WEEKDAY_RECEIPT_FIELDS')
        need(receipt['schemaVersion']==SELECTION_SCHEMA and receipt['JobID']==job,'WEEKDAY_RECEIPT_IDENTITY')
        docs={name:results.bound(directory+'/'+member,receipt[key],json_file=True) for name,member,key in (
            ('context','context.json','contextSHA256'),('execution','execution.json','executionSHA256'),
            ('validation','validation.json','validationSHA256'),('conversion','decimal_csv/conversion.json','conversionSHA256'))}
        self.context=context=docs['context']; self.receipt=receipt
        need(context.get('schemaVersion')=='transfusion-analysis/weekday-context-v1' and context.get('task')=='WEEKDAY' and context.get('job')==self.plan,'WEEKDAY_CONTEXT_PLAN')
        self.selected=context['selection']; self.corrected=check_selection(self.selected)
        identity,expected,native_parent=context['identity'],context['expected'],context['parentIdentity']
        # The parent model assigns an identifier to its reference profile.
        parent={key:expected[key] for key in PARENT_FIELDS if key!='ProfileIdentityKind'}
        parent['ProfileIdentityKind']='ASSIGNED_ID_NOT_CONTENT_HASH';self.parent=parent
        need(parent['CohortMode']=='full_cohort' and parent['InputSnapshotId']==results.index['inputSnapshotId'],'WEEKDAY_FULL_COHORT')
        need(all(expected[k]==value for k,value in self.plan.items()) and all(native_parent[k]==parent[k] for k in ('RunId','AnalysisSpecId','CohortMode','InputSnapshotId','CodeHash','ConfigHash')),'WEEKDAY_PARENT_IDENTITY')
        need(all(identity[k]==parent[k] for k in ('RunId','CohortMode','InputSnapshotId','CodeHash','ConfigHash')),'WEEKDAY_PREPARATION_IDENTITY')
        binding=context['parent']; exact(binding,('contextSHA256','executionSHA256','meanFitSHA256','workingValidationSHA256'),'WEEKDAY_PARENT_BINDINGS')
        for value in binding.values(): need(isinstance(value,str) and f.HEX.fullmatch(value),'WEEKDAY_PARENT_HASH')
        parent_dir='models/'+job
        original=results.bound(parent_dir+'/context.json',binding['contextSHA256'],json_file=True)
        results.bound(parent_dir+'/execution.json',binding['executionSHA256'],json_file=True)
        working=results.bound(parent_dir+'/working_validation.json',binding['workingValidationSHA256'],json_file=True)
        need(original.get('task')=='MODEL' and original.get('job')==self.plan and original.get('identity')==native_parent and all(original['expected'][k]==parent[k] for k in PARENT_FIELDS if k!='ProfileIdentityKind'),'WEEKDAY_PARENT_CONTEXT')
        need(binding['meanFitSHA256']==parent['CodeHash'],'WEEKDAY_PARENT_CODE')
        need(working.get('contextHash')==sha(canonical(original)) and working.get('validation',{}).get('status')=='VALIDATED' and working['validation'].get('scope')=='WORKING_MODEL_ONLY','WEEKDAY_WORKING_VALIDATION')
        execution,validation,conversion=docs['execution'],docs['validation'],docs['conversion']; context_hash=sha(canonical(context))
        need(execution.get('completed') is True and execution.get('contextHash')==context_hash,'WEEKDAY_EXECUTION_INCOMPLETE')
        need(validation.get('contextHash')==context_hash and validation.get('validation',{}).get('status')=='VALIDATED','WEEKDAY_VALIDATION_REQUIRED')
        need(conversion.get('numericFormat')=='PY_REPR_BINARY64' and conversion.get('validationSha256')==receipt['validationSHA256'] and conversion.get('publicReleaseAuthorized') is False,'WEEKDAY_CONVERSION_BINDING')
        known=validation['validation'].get('inputHashes'); allowed={name+'.csv' for name in PUBLIC_ROLES}
        need(isinstance(known,dict) and {'exact/'+name for name in allowed} <= set(known),'WEEKDAY_VALIDATED_ROLE_SET')
        for name,value in known.items():
            f.relative_path(results.root,directory+'/'+name)
            need(isinstance(value,str) and f.HEX.fullmatch(value),'WEEKDAY_VALIDATED_INPUT_HASH')
        self.converted={}
        for record in conversion.get('files',[]):
            exact(record,('file','sourceSha256','decimalSha256'),'WEEKDAY_CONVERSION_FIELDS'); name=record['file']
            need(name in allowed and name not in self.converted and record['sourceSha256']==known['exact/'+name],'WEEKDAY_CONVERSION_SOURCE')
            need(all(isinstance(record[k],str) and f.HEX.fullmatch(record[k]) for k in ('sourceSha256','decimalSha256')),'WEEKDAY_CONVERSION_HASH')
            self.converted[name]=record
        need(set(self.converted)==allowed,'WEEKDAY_CONVERSION_INCOMPLETE')
        self.roles={role:self.read_role(role) for role in PUBLIC_ROLES}
        check_role_values(self.roles,{'Model':self.selected})
        need(len(self.roles['reference_profile'][1])==1,'WEEKDAY_PROFILE_COUNT')
        if self.corrected:
            # Check that the validation and converted results select the same coefficients.
            evidence=validation['validation'].get('selectedMeanEvidence',{})
            exact(evidence,('CandidateMeanID','solutionSHA256','trajectorySHA256'),'WEEKDAY_SELECTED_MEAN_EVIDENCE')
            need(evidence['CandidateMeanID']==self.selected['CandidateMeanID'],'WEEKDAY_SELECTED_MEAN_PAIRING')
            for field in ('solutionSHA256','trajectorySHA256'):
                need(isinstance(evidence[field],str) and f.HEX.fullmatch(evidence[field]),'WEEKDAY_SELECTED_MEAN_HASH')
        self.origins={'parent':binding,'selectedMean':self.selected,'selectionSHA256':entry['selectionSHA256'],**receipt}

    def read_role(self,role):
        record=self.converted[role+'.csv']; raw=self.results.bound(self.entry['directory']+'/decimal_csv/'+role+'.csv',record['decimalSha256'])
        reader=csv.reader(io.StringIO(raw.decode('utf-8-sig'),newline=''),strict=True); header=next(reader)
        schema=next((variant for variant in SCHEMAS[role] if set(header)==set(variant)),None)
        need(schema is not None and len(header)==len(set(header)),'WEEKDAY_COLUMN_SCHEMA')
        if role == 'reference_profile':
            need(('Pressors_1' in schema) == (self.plan['Model'] == 'FULL'),
                 'WEEKDAY_PROFILE_MODEL_MISMATCH')
        rows=[]
        from model_adapter import no_private_text
        for cells in reader:
            need(len(cells)==len(header),'WEEKDAY_ROW_WIDTH')
            row={key:f.typed_number(value) if schema[key]=='numeric' else value for key,value in zip(header,cells)}
            for key in row:
                if key in self.parent: need(row[key]==self.parent[key],'WEEKDAY_ROW_PARENT_MISMATCH')
                if schema[key]=='char': no_private_text(row[key])
            rows.append(row)
        return header,rows,record['decimalSha256']

    def tables(self,release_id,key):
        context={**self.parent,**{k:self.plan[k] for k in ('Model','FactorName','VitalCode')},**self.selected,
                 'CompanionProtocol':PROTOCOL,'CompanionManifestSHA256':self.entry['selectionSHA256'],
                 'EndpointJointSourceSHA256':self.roles['endpoint_joint'][2],'TrajectoryJointSourceSHA256':self.roles['trajectory_joint'][2]}
        roles=dict(self.roles); a,b=roles['endpoint_joint'],roles['trajectory_joint']; need(a[0]==b[0],'WEEKDAY_JOINT_SCHEMA')
        joint_binding=canonical({'endpoint_joint':a[2],'trajectory_joint':b[2]})+b'\n'
        roles['joint']=a[0],a[1]+b[1],sha(joint_binding)
        return {role:table(f,release_id,key,role,roles[role],context) for role in f.ROLES}

    def profile(self,release_id,key):
        reference={'OriginalMeanOrigin':{'AttemptId':self.parent['RunId']+'-'+self.plan['JobID']}}
        return profile_table(f,release_id,key,reference,self.parent,self.roles['reference_profile'])

def project_report(role,rows):
    if role not in {'factor_observed_data_summary','observed_covariance','observed_joint_covariance','observed_pairwise'}: return rows,0
    kept=[]
    for row in rows:
        weekday=row.get('Factor')=='wdy_donation' or row.get('FactorName')=='wdy_donation'
        fields=[k for k in ('CategoryCode','CategoryA','CategoryB') if k in row]
        need(not weekday or bool(fields),'WEEKDAY_REPORT_CATEGORY_MISSING')
        if not(weekday and any(row[k] in (1,7) for k in fields)):kept.append(row)
    return kept,len(rows)-len(kept)
