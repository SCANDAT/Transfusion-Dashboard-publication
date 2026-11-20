"""Independent checks for Monday-Friday estimates and cluster-robust inference.

The numerical checks retain the equations, tolerances and exact certificate replay
used for the study. Portable input binding is handled by weekday_validation.py.
No model fitting or source-data access occurs in this module.
"""
from pathlib import Path
import csv, hashlib, json, math, re, struct, io
import numpy as np
from scipy import stats
import certificate_archive_schema as cert
import scalar_availability as availability
import mapping_check as mapping

TARGET_SHA = 'eefab4e58bd55d5def4180117696cc4ecd9ae62faeaa1f42380032efdf3da43d'
MULT_SHA = '801e3333cc8c9c0961ca23b2359b82ee45518556f2d392dcd04f5221048ede93'
FRESH_SCALAR = 14411
class Rejected(ValueError): pass


def need(v,code):
 if not v:raise Rejected(code)

def sha(p):
 with Path(p).open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def read(p):return json.loads(Path(p).read_bytes())

def close(a,b,code,rtol=2e-7,atol=1e-10):
 a=np.asarray(a,dtype=float);b=np.asarray(b,dtype=float)
 need(a.shape==b.shape and np.isfinite(a).all()and np.isfinite(b).all()and np.all(np.abs(a-b)<=atol+rtol*np.abs(b)),code)

def same(a,b,code):need(np.array_equal(np.asarray(a),np.asarray(b),equal_nan=True),code)

def decode(v):
 if v in ('','.'):return math.nan
 need(bool(re.fullmatch(r'H[0-9A-F]{16}',v)),'NUMERIC_TRANSPORT')
 z=struct.unpack('>d',bytes.fromhex(v[1:]))[0];need(math.isfinite(z),'NONFINITE_NATIVE_VALUE');return z

class Table:
 def __init__(self,path,pin=None):
  self.path=Path(path);before=self.path.stat();need(0<before.st_size<=256*2**20 and not self.path.is_symlink(),'TABLE_SCOPE')
  raw=self.path.read_bytes();after=self.path.stat();need((before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns),'TABLE_CHANGED')
  self.initial_state=(after.st_size,after.st_mtime_ns,after.st_ino);self.sha=hashlib.sha256(raw).hexdigest();need(pin is None or pin==self.sha,'ORIGINAL_TABLE_PIN')
  rd=csv.DictReader(io.StringIO(raw.decode('utf-8-sig'),newline=''));self.headers=rd.fieldnames or []
  need(self.headers and len(set(x.lower()for x in self.headers))==len(self.headers),'TABLE_HEADERS')
  self.key={x.lower():x for x in self.headers};self._n={};self._c={};self.rows=list(rd);need(all(None not in x and None not in x.values()for x in self.rows),'TABLE_ROWS')
 def n(self,key):
  need(key.lower()in self.key,'NUMERIC_COLUMN_MISSING');k=self.key[key.lower()]
  if k not in self._n:self._n[k]=np.array([decode(r[k])for r in self.rows])
  return self._n[k]
 def c(self,key):
  need(key.lower()in self.key,'CHARACTER_COLUMN_MISSING');k=self.key[key.lower()]
  if k not in self._c:self._c[k]=[r[k]for r in self.rows]
  return self._c[k]
 def mat(self,prefix='COL'):
  names=sorted((x for x in self.headers if re.fullmatch(prefix+r'\d+',x,re.I)),key=lambda x:int(re.search(r'\d+$',x)[0]))
  need(names and [int(re.search(r'\d+$',x)[0])for x in names]==list(range(1,len(names)+1)),'MATRIX_COLUMNS')
  return np.column_stack([self.n(x)for x in names])
 def numeric_rows(self,fields):return [{k:float(self.n(k)[i])for k in fields}for i in range(len(self.rows))]
 def metadata(self):
  st=self.path.stat();need((st.st_size,st.st_mtime_ns,st.st_ino)==self.initial_state,'TABLE_CHANGED_DURING_VALIDATION');return {'Path':str(self.path),'SHA256':self.sha,'Bytes':st.st_size}

def dense_long(t,r,c):
 ri=t.n(r);ci=t.n(c);need(np.isfinite(ri).all()and np.isfinite(ci).all()and(ri>=1).all()and(ci>=1).all()and(ri==ri.astype(int)).all()and(ci==ci.astype(int)).all(),'MATRIX_KEYS')
 need(len(set(zip(ri,ci)))==len(ri),'MATRIX_DUPLICATE');a=np.full((int(ri.max()),int(ci.max())),np.nan);a[ri.astype(int)-1,ci.astype(int)-1]=t.n('Value');need(np.isfinite(a).all(),'MATRIX_INCOMPLETE');return a

def packed_transform(t):
 q,h=t.shape;u,v=np.triu_indices(q);a,b=np.triu_indices(h);z=(t[u[:,None],a]*t[v[:,None],b]+t[u[:,None],b]*t[v[:,None],a]);z[:,a==b]/=2
 return z*np.sqrt(2-(u==v))[:,None]/np.sqrt(2-(a==b))[None,:]

def check_spd(a,code,pd=False):
 need(a.ndim==2 and a.shape[0]==a.shape[1]and np.isfinite(a).all(),code)
 need(np.linalg.norm(a-a.T)<=2e-8*max(np.linalg.norm(a),np.finfo(float).tiny),code)
 val=np.linalg.eigvalsh((a+a.T)/2);need(val[-1]>0 and(val[0]>1e-12*val[-1]if pd else val[0]>=-2e-8*val[-1]),code)

def covariance_close(a,b,code):
 need(np.diag(b).min()>=-1e-10*max(np.diag(b).max(),np.finfo(float).tiny),code);d=np.sqrt(np.maximum(np.diag(b),0))
 need(np.all(np.abs(a-b)<=1e-10+2e-6*np.outer(d,d))and np.linalg.norm(a-b)<=2e-7*max(np.linalg.norm(b),np.finfo(float).tiny),code)

def original_loader(case):
 refs={Path(x['Path']).name.lower():x for x in case['Files']if str(x['Path']).lower().endswith('.csv')}
 def get(name):
  need(name.lower()in refs,'ORIGINAL_ROLE_UNRESOLVED');r=refs[name.lower()];return Table(r['Path'],r['SHA256'])
 return get

def target_recipe(score,anchors,category_map):
 code=score.n('CategoryCode');idx=score.n('CategoryIndex');tm=score.n('TimeFromTransfusion');gid=score.n('GridID');sx=score.mat('RBCX');ax=anchors.mat('RBCX')
 maps={int(x['CategoryCode']):int(x['CategoryIndex'])for x in category_map};need(set(range(2,7))<=set(maps),'FIVE_CODES_UNAVAILABLE')
 levels=[];changes=[];within=[];keys=[];lookup={};pos=0
 for cat in range(2,7):
  rows=np.flatnonzero(code==cat);rows=rows[np.argsort(tm[rows])];same(tm[rows],np.arange(-720,721),'ORIGINAL_MINUTE_GRID');same(idx[rows],np.full(1441,maps[cat]),'ORIGINAL_CATEGORY_INDEX');need(len(set(gid[rows]))==1441,'ORIGINAL_GRID_KEYS')
  lookup[cat]=rows;levels.extend(sx[rows]);changes.extend(sx[rows]-sx[rows[660]]);within.append(sx[rows[780]]-sx[rows[660]])
 for kind in(1,2):
  for cat in range(2,7):
   for r in lookup[cat]:pos+=1;keys.append([pos,kind,gid[r],maps[cat],np.nan,tm[r],cat,np.nan])
 for cat in range(2,7):pos+=1;keys.append([pos,3,np.nan,maps[cat],np.nan,60,cat,np.nan])
 pairs=[]
 for ca in range(2,7):
  for cb in range(ca+1,7):pos+=1;keys.append([pos,4,np.nan,maps[ca],maps[cb],60,ca,cb]);pairs.append(within[ca-2]-within[cb-2])
 target=np.asarray(levels+changes+within+pairs);need(pos==14425 and target.shape[0]==14425,'TARGET_CARDINALITY')
 endpoint=np.array([within[c-2]-within[0]for c in range(3,7)])
 anchor_lookup={}
 for c in range(2,7):
  rows=np.flatnonzero(anchors.n('CategoryCode')==c);need(len(rows)==9,'ANCHOR_COUNT');order=rows[np.argsort(anchors.n('TimeFromTransfusion')[rows])]
  same(anchors.n('TimeFromTransfusion')[order],np.array([-720,-660,-360,-60,0,60,360,660,720]),'ANCHOR_TIMES');same(anchors.n('CategoryIndex')[order],np.full(9,maps[c]),'ANCHOR_CATEGORY_INDEX');anchor_lookup[c]={int(anchors.n('TimeFromTransfusion')[r]):ax[r]for r in order}
 whole=np.array([anchor_lookup[c][t]-anchor_lookup[c][0]-anchor_lookup[2][t]+anchor_lookup[2][0]for c in range(3,7)for t in(-660,-360,-60,60,360,660)])
 return target,np.array(keys),endpoint,whole,lookup,maps

def exact_binary64(a,b,code):
 a=np.asarray(a,dtype=np.float64);b=np.asarray(b,dtype=np.float64)
 need(a.shape==b.shape and np.array_equal(np.isnan(a),np.isnan(b)),code)
 mask=~np.isnan(a);need(np.array_equal(a[mask].view(np.uint64),b[mask].view(np.uint64)),code)

def inherited_scalar_proof(observed,new,getold,W,tables,job):
 oldrows={}
 for role in ['levels','changes','within','pairwise']:
  t=getold('C'+job[1:]+'_'+role+'.csv')
  for i,key in enumerate(t.c('TargetID')):need(key not in oldrows,'ACCEPTED_TARGET_DUPLICATE');oldrows[key]=(t,i)
 oldw=getold('C'+job[1:]+'_si_scalar_weights.csv');oldc=getold('C'+job[1:]+'_si_scalar_certificate.csv');oldweights=oldw.mat();wi={int(x):i for i,x in enumerate(oldw.n('TargetIndex'))};ci={int(x):i for i,x in enumerate(oldc.n('TargetIndex'))}
 need(len(wi)==len(oldw.rows)and len(ci)==len(oldc.rows),'ORIGINAL_CERTIFICATE_KEYS')
 newcert={int(x['TargetIndex']):x for x in tables['scalar_certificate']}
 numeric=['Estimate','StdErr','DF','tValue','Probt','Lower','Upper','Variance','ReferenceVariance','ContrastStatus','BaselineMinute','EndpointMinute','TargetKind','GridID','CategoryIndexA','CategoryIndexB','TimeFromTransfusion','CategoryCodeA','CategoryCodeB']
 chars=['NumericStatus','TargetRole','CIAdjustment','OriginalTargetRole']
 for i,(t,j)in enumerate(observed):
  key=t.c('OriginalTargetID')[j];need(key in oldrows,'ACCEPTED_TARGET_MISSING');old,k=oldrows[key];oid=int(old.n('TargetIndex')[k]);need(oid in wi and oid in ci,'ACCEPTED_CERTIFICATE_MISSING')
  for f in numeric:exact_binary64(t.n(f)[j],old.n(f)[k],'INHERITED_SCALAR_CHANGED')
  for f in ['NumericStatus','TargetRole','CIAdjustment']:need(t.c(f)[j]==old.c(f)[k],'INHERITED_STATUS_CHANGED')
  exact_binary64(W[i],oldweights[wi[oid]],'INHERITED_WEIGHTS_CHANGED')
  for f,value in newcert[i+1].items():
   if f!='TargetIndex':exact_binary64(value,oldc.n(f)[ci[oid]],'INHERITED_CERTIFICATE_CHANGED')
 return {'Status':'EXACT_ACCEPTED_SCALARS_WEIGHTS_CERTIFICATES_REINDEXED','ScalarTargetsCompared':len(observed),'OriginalCertificateRowsReusedWithoutFullReplay':True,'FreshPrespecifiedScalarTarget':FRESH_SCALAR,'OldAndNewEntrywiseErrorBoundsPreserved':True,'OriginalMarginalCSVsUsedAsJointProof':False}

def validate_saved(output, case, construction_source_sha, candidate_context=None, accepted_proof=None):
 job=case['OriginalModelAndNewTargets']['JobID']
 need(re.fullmatch(r'M[0-9]{4}',job) is not None and output.is_dir(),'VALIDATION_OUTPUT_SCOPE')
 need(re.fullmatch('[0-9a-f]{64}',construction_source_sha) is not None,'CONSTRUCTION_HASH_REQUIRED')
 getold=original_loader(case);prefix='C'+job[1:];loaded={}
 scope=case['Scope'];need(scope in {'FULL_COHORT_MODEL_INFERENCE','LOCAL_SAMPLE_MODEL_INFERENCE'},'INFERENCE_SCOPE')
 def new(role):
  if role not in loaded:loaded[role]=Table(output/'csv'/(prefix+'_'+role+'.csv'))
  return loaded[role]
 if candidate_context is None:
  complete=read(output/'native_complete.json');need(complete.get('Protocol')=='MONDAY_FRIDAY_SAVED_PILOT_EXPORT_COMPLETE_V1'and complete.get('JobID')==job and complete.get('NativeExportComplete')is True and complete.get('MeanRefitPerformed')is False,'NATIVE_EXPORT_INCOMPLETE')
  status=read(output/'producer_status.json');need(status.get('JobID')==job,'PRODUCER_CASE_STATUS');need(status.get('Protocol')=='MONDAY_FRIDAY_SAVED_PILOT_NATIVE_V1'and status.get('ProducerIntegrationPASS')==1 and status.get('MeanRefitPerformed')is False,'PRODUCER_REJECTED_COMPANION')
 else:
  complete=read(output/'native_complete.json');status=read(output/'producer_status.json')
  need(complete.get('Protocol')==job+'_FIXED_COVARIANCE_CANDIDATE_EXPORT_COMPLETE_V1' and complete.get('NativeExportComplete') is True,'NATIVE_EXPORT_INCOMPLETE')
  need(status.get('Protocol')==job+'_FIXED_COVARIANCE_CANDIDATE_NATIVE_V1' and status.get('ProducerIntegrationPASS')==1,'PRODUCER_REJECTED_COMPANION')
  for marker in (complete,status):
   need(marker.get('JobID')==job and marker.get('FixedCovarianceMeanSolutionUsed') is True and marker.get('OriginalMeanArchiveChanged') is False and marker.get('VarianceRefitPerformed') is False and marker.get('CandidateMeanID')==candidate_context['CandidateMeanID'] and 'MeanRefitPerformed' not in marker,'CANDIDATE_MEAN_PROVENANCE')
 identity=getold(job+'_identity.csv');newid=new('identity');need(len(identity.rows)==len(newid.rows)==1,'IDENTITY_COUNT')
 for key in ['RunId','AnalysisSpecId','CohortMode','PopulationId','FitId','InputSnapshotId','CodeHash','ConfigHash','DesignId','ProfileId','JobID']:
  need(newid.c(key)==identity.c(key),'ORIGINAL_IDENTITY_CHANGED')
 exact={'AmendmentID':'MONDAY_FRIDAY_REPORTING_AMENDMENT','AmendmentTiming':'POST_START_REPORTING_AMENDMENT','TargetSetID':job+'_MONDAY_FRIDAY_V1_eefab4e58bd5','ReportingReference':'MONDAY','ReportingSchema':'RBC_MONDAY_FRIDAY_COMPANION_V1','TargetRecipeSHA256':TARGET_SHA,'MultiplicitySHA256':MULT_SHA}
 for k,v in exact.items():need(newid.c(k)==[v],'COMPANION_IDENTITY')
 native_status=new('status');need(native_status.c('IntegrationStatus')==['CR2_CHECKS_PASSED']and native_status.c('ReasonCode')==['PASS'],'NATIVE_INTEGRATION_STATUS')
 need(newid.c('CR2Protocol')[0]in {'RBC_CR2_MONDAY_FRIDAY_V1','RBC_CR2_MONDAY_FRIDAY_LCPU_V1'},'COMPANION_PROTOCOL')
 meanmeta=getold(job+'_fitmetadata.csv')
 for key in ['Model','FactorName','VitalCode']:need(meanmeta.c(key)==[case['OriginalModelAndNewTargets'][key]],'ORIGINAL_MODEL_SPECIFICATION')
 score=getold(job+'_score_design.csv');anchor=getold(job+'_anchor_design.csv');solution=getold(job+'_solution.csv')
 targets,keys,endpoint,whole,lookup,codemap=target_recipe(score,anchor,case['OriginalCategoryMapping']);p=targets.shape[1]
 need(meanmeta.n('N_DesignColumns')[0]==p,'ORIGINAL_PARAMETER_COUNT');beta=np.zeros(p);seen=set()
 for effect,value in zip(solution.c('Effect'),solution.n('Estimate')):
  match=re.fullmatch(r'RBCX([1-9][0-9]*)',effect.strip(),re.I);need(match is not None,'ORIGINAL_SOLUTION_SCHEMA');i=int(match[1]);need(1<=i<=p and i not in seen,'ORIGINAL_SOLUTION_KEYS');seen.add(i);beta[i-1]=value
 need(len(seen)==p,'ORIGINAL_SOLUTION_COMPLETENESS')
 if candidate_context is not None:
  need(np.array_equal(beta,candidate_context['OriginalBeta']),'CANDIDATE_PARENT_BETA_MISMATCH')
  beta=candidate_context['Beta'].copy();need(beta.shape==(p,) and np.isfinite(beta).all(),'CANDIDATE_BETA_SCHEMA')
 td=new('target_design');tk=new('target_keys');same(td.n('TargetIndex'),np.arange(1,14426),'TARGET_INDICES');close(td.mat('RBCX'),targets,'EXACT_TARGET_RECIPE',rtol=2e-10,atol=1e-12)
 keynames=['TargetIndex','TargetKind','GridID','CategoryIndexA','CategoryIndexB','TimeFromTransfusion','CategoryCodeA','CategoryCodeB'];same(np.column_stack([tk.n(k)for k in keynames]),keys,'TARGET_KEYS')
 ctx=new('si_context');need(len(ctx.rows)==1,'CONTEXT_COUNT');need(ctx.c('RunId')==identity.c('RunId')and ctx.c('FitId')==identity.c('FitId')and ctx.c('Scope')==[scope],'NATIVE_CONTEXT_IDENTITY');h=int(ctx.n('SpanDimension')[0]);dim=h*(h+1)//2
 anchor_rows=anchor.mat('RBCX')[np.isin(anchor.n('CategoryCode'),np.arange(2,7))];anchor_s=np.linalg.svd(anchor_rows.T,compute_uv=False);anchor_rank=int(np.sum(anchor_s>1e-10*anchor_s[0]));need(h==anchor_rank and 1<=h<=min(p,45)and ctx.n('MomentDimension')[0]==dim,'DERIVED_SPAN_DIMENSION');need(ctx.n('DesignRank')[0]==meanmeta.n('N_Used')[0]-meanmeta.n('ResidualDF')[0]and ctx.n('ParameterCount')[0]==p and ctx.n('ClusterCount')[0]==meanmeta.n('N_Patients')[0],'FULL_FIT_DIMENSIONS_CHANGED')
 need(ctx.n('TargetCalibrationVerified')[0]==1 and ctx.n('AllCoefficientsCalibrated')[0]==0 and ctx.c('CalibrationDomain')==['FIXED_PREDECLARED_TARGET_SPAN']and ctx.c('StructuralCertificate')==['RAW_LITERAL_SUPPORT_V1'],'NATIVE_ALL_DELETION_CALIBRATION');need(new('si_status').c('cr2rc')==['PASS'],'NATIVE_KERNEL_STATUS')
 CB=new('si_spanbasis').mat();VR=new('si_spanrobust').mat();M=new('si_moment').mat();E=new('si_moment_error').mat();need(CB.shape==(h,p)and VR.shape==(h,h)and M.shape==E.shape==(dim,dim),'NATIVE_MATRIX_SHAPES');check_spd(VR,'ROBUST_COVARIANCE');need(np.isfinite(E).all()and(E>=0).all(),'MOMENT_ERROR_BOUNDS')
 us,sv,vt=np.linalg.svd(CB,full_matrices=False);need(sv[-1]>1e-6*sv[0],'SCORE_SPAN_RANK');CBplus=(vt.T/sv)@us.T
 basis=dense_long(new('si_basis'),'Parameter','ActiveColumn');bread=dense_long(new('si_bread'),'Row','Col');fullbread=basis@bread@basis.T
 close(basis.T@basis,np.eye(basis.shape[1]),'FITTED_BASIS_ORTHONORMAL',rtol=0,atol=2e-9);check_spd(bread,'FULL_FIT_BREAD',pd=True);close(CB,CB@basis@basis.T,'FULL_FIT_TARGET_ESTIMABILITY',rtol=2e-8,atol=1e-9);close((CB@basis)@bread@(CB@basis).T,np.eye(h),'FULL_FIT_REFERENCE_CALIBRATION',rtol=2e-8,atol=1e-9)
 covariance=dense_long(new('si_covariance'),'Row','Col');check_spd(covariance,'FULL_FIT_ROBUST_COVARIANCE');covariance_close(covariance,basis@(basis.T@covariance@basis)@basis.T,'FULL_FIT_COVARIANCE_SUPPORT');covariance_close(VR,CB@covariance@CB.T,'FULL_FIT_SPAN_COVARIANCE')
 envelope=ctx.n('RoundoffEnvelope')[0];G=ctx.n('ClusterCount')[0];need(np.isfinite(envelope)and envelope>0 and np.linalg.norm(M-M.T)<=2e-10*np.linalg.norm(M),'MOMENT_SYMMETRY');mw=np.linalg.eigvalsh((M+M.T)/2);need(mw[-1]>0 and mw[0]>=-envelope-128*np.finfo(float).eps*mw[-1],'MOMENT_PSD');need(envelope>=np.finfo(float).eps*(64+8*G)*np.linalg.norm(M)*(1-2e-8),'MOMENT_ENVELOPE')
 oldcov=getold(job+'_covparms.csv');covlookup=dict(zip(oldcov.c('CovParm'),oldcov.n('Estimate')));need(set(covlookup)=={'Intercept','Residual'}and ctx.n('Tau2')[0]==covlookup['Intercept']and ctx.n('Sigma2')[0]==covlookup['Residual']and ctx.n('Alpha')[0]==.05,'ORIGINAL_WORKING_COVARIANCE_CHANGED')
 working=new('working_target');need(working.n('Tau2')[0]==ctx.n('Tau2')[0]and working.n('Sigma2')[0]==ctx.n('Sigma2')[0]and working.n('Alpha')[0]==.05 and working.n('ComponentCount')[0]==2 and working.n('RIComponents')[0]==working.n('ResidualComponents')[0]==1,'WORKING_TARGET_SCHEMA')
 reference_solution=new('si_solution');sx=np.zeros(p);sx[reference_solution.n('Parameter').astype(int)-1]=reference_solution.n('Estimate');close(sx,beta,'ORIGINAL_SOLUTION_CHANGED',rtol=0,atol=0)
 weights=new('si_scalar_weights');same(weights.n('TargetIndex'),np.arange(1,14426),'NATIVE_SCALAR_WEIGHT_KEYS');W=weights.mat();need(W.shape==(14425,h),'NATIVE_WEIGHT_DIMENSIONS');mapping.check_scalar_weight_mapping(W,targets@CBplus,lambda v,c:need(v,c));need(np.all(np.linalg.norm(targets-W@CB,axis=1)<=2e-8*np.linalg.norm(targets,axis=1)),'TARGET_OUTSIDE_SPAN')
 # Verify the stored error bounds using their native centers and radii and
 # directed decimal arithmetic when required.
 ct=new('certificate_context');fields=list(cert.CERTIFICATE_CONTEXT_CHARS+cert.CERTIFICATE_CONTEXT_NUMS)+['RunId','FitId','Scope'];context={k:(float(ct.n(k)[0])if k in cert.CERTIFICATE_CONTEXT_NUMS else ct.c(k)[0])for k in fields}
 tests=[{'TestIndex':i,'ConstraintIndices':list(range(1,n+1))}for i,n in[(1,4),(2,24)]]
 expected={'RunId':identity.c('RunId')[0],'FitId':identity.c('FitId')[0],'Scope':scope,'ConstructionSourceSHA256':construction_source_sha,'SpanDimension':h,'MomentDimension':dim,'TargetIndices':list(range(1,14426)),'Tests':tests}
 desc=cert.descriptor_from_context(context,target_indices=expected['TargetIndices'],tests=tests,expected=expected)
 rolemap={'moment_error':'si_moment_error','scalar_weights':'si_scalar_weights','scalar_certificate':'si_scalar_certificate','joint_weights':'joint_weights','joint_certificate':'joint_certificate'}
 tables={role:new(rolemap[role]).numeric_rows(cols)for role,(_,cols,count)in cert.schemas(desc).items()}
 replay=cert.validate_contractions(desc,tables,M,expected=expected)
 scalars={int(r['TargetIndex']):r for r in tables['scalar_certificate']};jcert={int(r['TestIndex']):r for r in tables['joint_certificate']}
 observed=[];role_counts={}
 for role,kind,count in [('levels',1,7205),('changes',2,7205),('within',3,5),('pairwise',4,10)]:
  t=new(role);need(len(t.rows)==count,'FINAL_ROLE_CARDINALITY');role_counts[role]=count
  for k in ['RunId','FitId','InputSnapshotId','CodeHash','JobID','ProfileId']:
   need(set(t.c(k))==set(identity.c(k)),'FINAL_ROLE_IDENTITY')
  for i in range(count):observed.append((t,i))
 order=np.argsort([t.n('TargetIndex')[i]for t,i in observed]);observed=[observed[i]for i in order]
 def field(k):return np.array([t.n(k)[i]for t,i in observed])
 same(np.column_stack([field(k)for k in keynames]),keys,'FINAL_TARGET_KEYS')
 zero=np.max(np.abs(targets),axis=1)==0;need(int(zero.sum())==5,'DETERMINISTIC_ZERO_COUNT');theta=targets@beta
 ia,ib=np.triu_indices(h);scale=np.sqrt(2-(ia==ib));variance=np.einsum('ij,jk,ik->i',W,VR,W);reference=np.sum(W*W,axis=1);den=np.empty(14425)
 for start in range(0,14425,128):
  w=W[start:start+128];v=scale*w[:,ia]*w[:,ib];den[start:start+len(w)]=np.einsum('ij,ij->i',v@M,v)
 unavailable=[];valid=[]
 for i,(t,j)in enumerate(observed):
  kind=int(keys[i,1]);targetid=('L_'if kind==1 else'C_')+f'{int(keys[i,2]):08d}'if kind in(1,2)else f'W_{int(keys[i,6])}'if kind==3 else f'P_{int(keys[i,6])}_{int(keys[i,7])}'
  need(t.c('TargetID')[j]=='MF1.'+targetid and t.c('OriginalTargetID')[j]==targetid and t.c('TargetRole')[j]==['LEVEL','CHANGE','WITHIN','PAIRWISE'][kind-1],'TARGET_LABELS')
  need(t.c('FamilyID')[j]==(job+'_HOLM10_V1_801e3333cc8c'if kind==4 else'NONE'),'NEW_FAMILY_ID')
  need(t.n('BaselineMinute')[j]==-60 and t.n('EndpointMinute')[j]==60,'TARGET_TIMES')
  need(t.c('CIAdjustment')[j]==('Deterministic zero'if zero[i]else'None: pointwise')and t.c('PAdjustment')[j]==('Holm within amended fixed family10'if kind==4 else'NONE'),'TARGET_ADJUSTMENT_LABEL')
  status=t.c('NumericStatus')[j];cs=t.n('ContrastStatus')[j]
  if zero[i]:
   need(status=='BASELINE_ZERO'and cs==2,'BASELINE_ZERO_STATUS')
   for f in ['Estimate','StdErr','Lower','Upper','Variance','ReferenceVariance']:need(t.n(f)[j]==0,'BASELINE_ZERO_VALUES')
   for f in ['DF','tValue','Probt']:need(math.isnan(t.n(f)[j]),'BASELINE_ZERO_NOT_INFERENCE')
  elif cs==4 and kind in(1,2):
   need(status=='MOMENT_PRECISION_UNRESOLVED'and availability.classify_native_certificate(scalars[i+1])=='PRECISION_UNRESOLVED','UNAVAILABLE_CERTIFICATE')
   for f in availability.UNCERTAINTY_FIELDS:need(math.isnan(t.n(f)[j]),'UNAVAILABLE_UNCERTAINTY_PRESENT')
   close(t.n('Estimate')[j],theta[i],'UNAVAILABLE_POINT',rtol=2e-7,atol=1e-9);unavailable.append(i)
  else:need(cs==0 and status=='COMPUTED'and scalars[i+1]['Resolved']==1,'SCALAR_DISPOSITION');valid.append(i)
 valid=np.array(valid,dtype=int);native=np.array([scalars[int(i)+1]['Denominator']for i in valid]);close(den[valid],native,'SCALAR_MOMENT',rtol=2e-7,atol=0)
 need(np.all(native>0)and np.all(variance[valid]>0)and np.all(reference[valid]>0),'SCALAR_GEOMETRY');df=reference[valid]**2/native;se=np.sqrt(variance[valid]);tv=theta[valid]/se;pv=2*stats.t.sf(np.abs(tv),df);crit=stats.t.ppf(.975,df)
 need(np.all(df>=1-1e-8)and np.all(df<=ctx.n('ClusterCount')[0]*(1+1e-8)),'SCALAR_DF_RANGE')
 for f,x in [('Estimate',theta[valid]),('StdErr',se),('DF',df),('tValue',tv),('Variance',variance[valid]),('ReferenceVariance',reference[valid])]:close(field(f)[valid],x,'SCALAR_'+f.upper(),rtol=2e-7,atol=1e-9)
 close(field('Probt')[valid],pv,'SCALAR_PROBABILITY',rtol=2e-7,atol=1e-10)
 for f,x in [('Lower',theta[valid]-crit*se),('Upper',theta[valid]+crit*se)]:close(field(f)[valid],x,'SCALAR_CI',rtol=2e-7,atol=2e-9*np.maximum.reduce([np.abs(theta[valid]),crit*se,np.full(len(valid),1e-6)]))
 pairs=new('pairwise');order=np.argsort(pairs.n('TargetIndex'));raw=pairs.n('Probt')[order];need(len(raw)==10 and np.isfinite(raw).all()and(raw>=0).all()and(raw<=1).all(),'TEN_RAW_P_REQUIRED');orderp=np.lexsort((pairs.n('TargetIndex')[order],raw));adj=np.empty(10);adj[orderp]=np.minimum(1,np.maximum.accumulate(raw[orderp]*np.arange(10,0,-1)));close(pairs.n('PValue_Holm')[order],adj,'HOLM_TEN',rtol=1e-12,atol=1e-15);need(set(pairs.c('PAdjustment'))=={'Holm within amended fixed family10'},'HOLM_LABEL')
 fam=new('family_plan');need(fam.c('FamilyID')==[job+'_HOLM10_V1_801e3333cc8c']and fam.c('FreezeStage')==['POST_START_AMENDMENT']and fam.n('PlanVersion')[0]==2,'AMENDED_FAMILY_IDENTITY')
 for f,n in [('PlannedCategories',5),('AvailableCategories',5),('PlannedPairs',10),('ActivePairs',10)]:same(fam.n(f),np.array([n]),'HOLM_FIXED_MEMBERSHIP')
 jd=new('joint_design');jr=new('joint');ra=new('joint_rank_audit');jw=new('joint_weights');joint_states=[]
 for test,C,label in [(1,endpoint,'MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY'),(2,whole,'MONDAY_FRIDAY_TRAJECTORY_INTERACTION')]:
  rows=np.flatnonzero(jd.n('TestIndex')==test);rows=rows[np.argsort(jd.n('ConstraintIndex')[rows])];same(jd.n('ConstraintIndex')[rows],np.arange(1,len(C)+1),'JOINT_KEYS');close(jd.mat('RBCX')[rows],C,'EXACT_NEW_NULL',rtol=2e-10,atol=1e-12)
  expected_categories=np.array([codemap[c]for c in range(3,7)]);expected_categories=expected_categories if test==1 else np.repeat(expected_categories,6);same(jd.n('CategoryIndex')[rows],expected_categories,'JOINT_ORIGINAL_CATEGORY_MAP');same(jd.n('AnchorIndex')[rows],np.full(4,np.nan)if test==1 else np.tile([2,3,4,6,7,8],4),'JOINT_EXACT_ANCHORS')
  w=C@CBplus;need(np.all(np.linalg.norm(C-w@CB,axis=1)<=2e-8*np.linalg.norm(C,axis=1)),'JOINT_SPAN');sc=np.linalg.norm(w,axis=1);need((sc>0).all(),'JOINT_ZERO_ROW');normalized=w/sc[:,None];u,s,vt=np.linalg.svd(normalized,full_matrices=False);rank=int(np.sum(s>1e-10*s[0]));ri=np.flatnonzero(ra.n('TestIndex')==test);need(len(ri)==1 and ra.n('DerivedRank')[ri[0]]==rank and ra.n('WrittenRows')[ri[0]]==len(C)and ra.n('ReferenceAdmissible')[ri[0]]==int(s[-1]>1e-6*s[0]),'DERIVED_NULL_RANK');need(rank==len(C)and s[-1]>1e-6*s[0],'REDUNDANT_NULL_REFUSED')
  wi=np.flatnonzero(jw.n('TestIndex')==test);wi=wi[np.argsort(jw.n('ConstraintIndex')[wi])];nativew=jw.mat()[wi];close(nativew@nativew.T,np.eye(rank),'JOINT_REFERENCE_CALIBRATION',rtol=0,atol=2e-8);need(np.all(np.linalg.norm(normalized-normalized@nativew.T@nativew,axis=1)<=2e-8*np.linalg.norm(normalized,axis=1)),'NATIVE_JOINT_NULL_CHANGED')
  sq=packed_transform(nativew);dm=2*float(np.sum(sq*(sq@M)));c=jcert[test];idx=np.flatnonzero(jr.n('TestIndex')==test);need(len(idx)==1,'JOINT_OUTPUT_COUNT');j=int(idx[0]);need(jr.c('TestRole')[j]==label,'JOINT_NULL_LABEL');close(np.array([jr.n(f)[j]for f in ['Q','DF1','MomentDenominator']]),np.array([rank,rank,c['Denominator']]),'JOINT_DIMENSIONS',rtol=2e-6,atol=1e-9)
  if c['Resolved']==1:close(dm,c['Denominator'],'JOINT_MOMENT',rtol=2e-6,atol=0)
  d=c['Denominator'];nu=rank*(rank+1)/d if d>0 else math.nan;df2=nu-rank+1
  if d>0:close(np.array([jr.n('Nu')[j],jr.n('DF2')[j]]),np.array([nu,df2]),'JOINT_DF',rtol=2e-6,atol=1e-9)
  state=jr.c('NumericStatus')[j];js=jr.n('JointStatus')[j]
  if c['Resolved']!=1:need(js==4 and state=='MOMENT_PRECISION_UNRESOLVED','JOINT_UNAVAILABLE');need(all(math.isnan(jr.n(f)[j])for f in['Wald','FValue','ProbF']),'JOINT_UNAVAILABLE_VALUES')
  else:
   obs=nativew@VR@nativew.T;check_spd(obs,'JOINT_OBSERVED_COVARIANCE',pd=True);theta_joint=nativew@CB@beta;wald=float(theta_joint@np.linalg.solve(obs,theta_joint));close(jr.n('Wald')[j],wald,'JOINT_WALD',rtol=2e-6,atol=1e-9)
   if c['DF2Sign']in(0,2):need(js==5 and state=='DF2_SIGN_UNRESOLVED','JOINT_SIGN_UNAVAILABLE')
   elif df2<=0:need(c['DF2Sign']==-1 and js==2 and state=='INSUFFICIENT_EFFECTIVE_DF','JOINT_DF_UNAVAILABLE')
   else:
    need(c['DF2Sign']==1 and js==int(df2<4)and state==('LOW_EFFECTIVE_DF'if df2<4 else'COMPUTED'),'JOINT_STATUS');fv=df2*wald/(nu*rank);close(jr.n('FValue')[j],fv,'JOINT_F',rtol=2e-6,atol=1e-10);close(jr.n('ProbF')[j],stats.f.sf(fv,rank,df2),'JOINT_P',rtol=2e-6,atol=1e-10)
   if c['DF2Sign']in(0,2)or df2<=0:need(math.isnan(jr.n('FValue')[j])and math.isnan(jr.n('ProbF')[j]),'JOINT_UNAVAILABLE_INFERENCE')
  joint_states.append({'TestIndex':test,'Null':label,'WrittenRows':len(C),'DerivedRank':rank,'Status':state})
 parity={'Status':'NOT_APPLICABLE_ORIGINAL_FAMILY_UNAVAILABLE','OriginalMarginalCSVsUsedAsJointProof':False}
 if job=='M0162':
  oldcb=getold(prefix+'_si_spanbasis.csv').mat();oldv=getold(prefix+'_si_spanrobust.csv').mat();oldm=getold(prefix+'_si_moment.csv').mat();olde=getold(prefix+'_si_moment_error.csv').mat();oldh=oldcb.shape[0];oldd=oldh*(oldh+1)//2;need(oldcb.shape[1]==p and oldv.shape==(oldh,oldh)and oldm.shape==olde.shape==(oldd,oldd)and np.isfinite(oldcb).all()and np.isfinite(oldv).all()and np.isfinite(oldm).all()and np.isfinite(olde).all()and(olde>=0).all(),'ACCEPTED_NATIVE_ARCHIVE_SCHEMA');T=CB@np.linalg.pinv(oldcb,rcond=1e-10);need(np.all(np.linalg.norm(CB-T@oldcb,axis=1)<=2e-8*np.linalg.norm(CB,axis=1)),'ACCEPTED_SPAN_CONTAINMENT');predv=T@oldv@T.T;close(VR,predv,'ACCEPTED_FULL_COVARIANCE_PROJECTION',rtol=2e-8,atol=2e-8)
  sd=np.sqrt(np.maximum(np.diag(predv),0));need(np.all(np.abs(VR-predv)<=1e-10+2e-6*np.outer(sd,sd))and np.linalg.norm(VR-predv)<=2e-7*max(np.linalg.norm(predv),np.finfo(float).tiny),'ORIGINAL_COVARIANCE_ACCEPTANCE')
  S=packed_transform(T);predm=S@oldm@S.T;transported=np.abs(S)@olde@np.abs(S).T;need(np.all(np.abs(M-predm)<=E+transported+2e-8*np.maximum(1,np.abs(predm))),'ACCEPTED_FULL_MOMENT_PROJECTION')
  oldrows={}
  for role in['levels','changes','within','pairwise']:
   old=getold(prefix+'_'+role+'.csv')
   for i,k in enumerate(old.c('TargetID')):need(k not in oldrows,'ACCEPTED_TARGET_DUPLICATE');oldrows[k]=(old,i)
  compared=0
  for i,(t,j)in enumerate(observed):
   key=t.c('OriginalTargetID')[j];need(key in oldrows,'ACCEPTED_TARGET_MISSING');old,k=oldrows[key]
   if old.c('NumericStatus')[k]=='COMPUTED':
    need(t.c('NumericStatus')[j]=='COMPUTED','ACCEPTED_SURVIVOR_BECAME_UNAVAILABLE')
    for f in['Estimate','StdErr','DF','tValue','Variance','ReferenceVariance']:close(t.n(f)[j],old.n(f)[k],'ACCEPTED_SCALAR_'+f.upper(),rtol=2e-7,atol=1e-9)
    close(t.n('Probt')[j],old.n('Probt')[k],'ACCEPTED_RAW_P',rtol=2e-7,atol=1e-10)
    for f in['Lower','Upper']:close(t.n(f)[j],old.n(f)[k],'ACCEPTED_CI',rtol=2e-7,atol=2e-9*max(abs(old.n('Estimate')[k]),abs(old.n(f)[k]-old.n('Estimate')[k]),1e-6))
    compared+=1
  parity={'Status':'ACCEPTED_FULL_NATIVE_SPAN_COVARIANCE_MOMENT_AND_SURVIVING_SCALARS_MATCH','ScalarTargetsCompared':compared,'OldAndNewEntrywiseErrorBoundsPreserved':True,'OriginalMarginalCSVsUsedAsJointProof':False}
 role_dispositions={role:{'Status':'VALIDATED','RequestedTargets':count,'ComputedTargets':count,'UnavailableTargets':0}for role,count in role_counts.items()}
 for role,kind in [('levels',1),('changes',2)]:
  n=sum(int(keys[i,1])==kind for i in unavailable);role_dispositions[role].update(Status='VALIDATED_WITH_EXPLICIT_UNAVAILABLE_TARGETS'if n else'VALIDATED',ComputedTargets=role_counts[role]-n-(5 if role=='changes'else 0),UnavailableTargets=n,DeterministicZeroTargets=5 if role=='changes'else 0)
 for item,role in zip(joint_states,['endpoint_joint','trajectory_joint']):role_dispositions[role]={'Status':item['Status'],'ValidatedDisposition':True,'DerivedRank':item['DerivedRank']}
 profile_refs=[{'Path':f['Path'],'SHA256':f['SHA256']}for f in case['Files']if Path(f['Path']).name.lower()==(job+'_profile.csv').lower()]
 need(len(profile_refs)==1,'ORIGINAL_PROFILE_BINDING_REQUIRED')
 return {'RoleDispositions':role_dispositions,'Status':'PASS','JobID':job,
         'CompleteSupportedCompanion':not unavailable and all(j['Status']in ['COMPUTED','LOW_EFFECTIVE_DF']for j in joint_states),
         'RequestedTargets':14425,'RoleCounts':role_counts,'DeterministicZeros':5,
         'ComputedScalarTargets':len(valid),'PrecisionUnavailableScalarTargets':len(unavailable),
         'JointDispositions':joint_states,
         'CertificateReplay':{k:v for k,v in replay.items()if k not in ['NativeUnresolvedScalarTargets','NativeUnresolvedDecimalVerified','NativeUnresolvedReplayResolves']},
         'AcceptedReferenceComparison':parity,'Files':[t.metadata()for t in loaded.values()],
         'ReferenceProfileBinding':profile_refs,'FullFitDenominatorsPreserved':True}


def validate_reuse(output, case, construction_source_sha, candidate_context=None, accepted_proof=None):
 job=case['OriginalModelAndNewTargets']['JobID']
 need(re.fullmatch(r'M[0-9]{4}',job) is not None and output.is_dir(),'VALIDATION_OUTPUT_SCOPE')
 need(re.fullmatch('[0-9a-f]{64}',construction_source_sha) is not None,'CONSTRUCTION_HASH_REQUIRED')
 getold=original_loader(case);prefix='C'+job[1:];loaded={}
 scope=case['Scope'];need(scope in {'FULL_COHORT_MODEL_INFERENCE','LOCAL_SAMPLE_MODEL_INFERENCE'},'INFERENCE_SCOPE')
 def new(role):
  if role not in loaded:loaded[role]=Table(output/'csv'/(prefix+'_'+role+'.csv'))
  return loaded[role]
 need(candidate_context is None and isinstance(accepted_proof,dict),'ACCEPTED_PARENT_PROOF_REQUIRED')
 ORIGINAL_CONSTRUCTION=construction_source_sha
 reuse=read(output/'reuse_provenance.json');need(reuse['Protocol']=='MONDAY_FRIDAY_ACCEPTED_FULL_SPAN_REUSE_V1'and reuse['ExecutionMode']=='ACCEPTED_FULL_SPAN_REUSE'and reuse['JobID']==job and reuse['OriginalMomentConstructionSourceSHA256']==ORIGINAL_CONSTRUCTION and reuse['MeanRefitPerformed']is False and reuse['FullMomentReconstructionPerformed']is False and reuse['ReusedScalarResults']is True and reuse['ReusedFullSpanMatrices']is True and reuse['RecomputedJointTests']==[1,2]and reuse['OriginalSevenDayStatusChanged']is False,'REUSE_EXECUTION_PROVENANCE')
 complete=read(output/'native_complete.json');need(complete.get('Protocol')=='MONDAY_FRIDAY_SAVED_PILOT_EXPORT_COMPLETE_V1'and complete.get('JobID')==job and complete.get('NativeExportComplete')is True and complete.get('MeanRefitPerformed')is False and complete.get('ExecutionMode')=='ACCEPTED_FULL_SPAN_REUSE','NATIVE_EXPORT_INCOMPLETE')
 status=read(output/'producer_status.json');need(status.get('JobID')==job,'PRODUCER_CASE_STATUS');need(status.get('Protocol')=='MONDAY_FRIDAY_SAVED_PILOT_NATIVE_V1'and status.get('ProducerIntegrationPASS')==1 and status.get('MeanRefitPerformed')is False and status.get('ExecutionMode')=='ACCEPTED_FULL_SPAN_REUSE','PRODUCER_REJECTED_COMPANION')
 identity=getold(job+'_identity.csv');newid=new('identity');need(len(identity.rows)==len(newid.rows)==1,'IDENTITY_COUNT')
 for key in ['RunId','AnalysisSpecId','CohortMode','PopulationId','FitId','InputSnapshotId','CodeHash','ConfigHash','DesignId','ProfileId','JobID']:
  need(newid.c(key)==identity.c(key),'ORIGINAL_IDENTITY_CHANGED')
 exact={'AmendmentID':'MONDAY_FRIDAY_REPORTING_AMENDMENT','AmendmentTiming':'POST_START_REPORTING_AMENDMENT','TargetSetID':job+'_MONDAY_FRIDAY_V1_eefab4e58bd5','ReportingReference':'MONDAY','ReportingSchema':'RBC_MONDAY_FRIDAY_COMPANION_V1','TargetRecipeSHA256':TARGET_SHA,'MultiplicitySHA256':MULT_SHA}
 for k,v in exact.items():need(newid.c(k)==[v],'COMPANION_IDENTITY')
 native_status=new('status');need(native_status.c('IntegrationStatus')==['CR2_CHECKS_PASSED']and native_status.c('ReasonCode')==['PASS'],'NATIVE_INTEGRATION_STATUS')
 need(newid.c('CR2Protocol')[0]in {'RBC_CR2_MONDAY_FRIDAY_V1','RBC_CR2_MONDAY_FRIDAY_LCPU_V1'},'COMPANION_PROTOCOL')
 meanmeta=getold(job+'_fitmetadata.csv')
 for key in ['Model','FactorName','VitalCode']:need(meanmeta.c(key)==[case['OriginalModelAndNewTargets'][key]],'ORIGINAL_MODEL_SPECIFICATION')
 score=getold(job+'_score_design.csv');anchor=getold(job+'_anchor_design.csv');solution=getold(job+'_solution.csv')
 targets,keys,endpoint,whole,lookup,codemap=target_recipe(score,anchor,case['OriginalCategoryMapping']);p=targets.shape[1]
 need(meanmeta.n('N_DesignColumns')[0]==p,'ORIGINAL_PARAMETER_COUNT');beta=np.zeros(p);seen=set()
 for effect,value in zip(solution.c('Effect'),solution.n('Estimate')):
  match=re.fullmatch(r'RBCX([1-9][0-9]*)',effect.strip(),re.I);need(match is not None,'ORIGINAL_SOLUTION_SCHEMA');i=int(match[1]);need(1<=i<=p and i not in seen,'ORIGINAL_SOLUTION_KEYS');seen.add(i);beta[i-1]=value
 need(len(seen)==p,'ORIGINAL_SOLUTION_COMPLETENESS')
 td=new('target_design');tk=new('target_keys');same(td.n('TargetIndex'),np.arange(1,14426),'TARGET_INDICES');close(td.mat('RBCX'),targets,'EXACT_TARGET_RECIPE',rtol=2e-10,atol=1e-12)
 keynames=['TargetIndex','TargetKind','GridID','CategoryIndexA','CategoryIndexB','TimeFromTransfusion','CategoryCodeA','CategoryCodeB'];same(np.column_stack([tk.n(k)for k in keynames]),keys,'TARGET_KEYS')
 ctx=new('si_context');need(len(ctx.rows)==1,'CONTEXT_COUNT');need(ctx.c('RunId')==identity.c('RunId')and ctx.c('FitId')==identity.c('FitId')and ctx.c('Scope')==[scope],'NATIVE_CONTEXT_IDENTITY');h=int(ctx.n('SpanDimension')[0]);dim=h*(h+1)//2
 anchor_rows=anchor.mat('RBCX')[np.isin(anchor.n('CategoryCode'),np.arange(2,7))];anchor_s=np.linalg.svd(anchor_rows.T,compute_uv=False);anchor_rank=int(np.sum(anchor_s>1e-10*anchor_s[0]));need(1<=anchor_rank<=h<=p and ctx.n('MomentDimension')[0]==dim,'ACCEPTED_FULL_SPAN_DIMENSION');need(ctx.n('DesignRank')[0]==meanmeta.n('N_Used')[0]-meanmeta.n('ResidualDF')[0]and ctx.n('ParameterCount')[0]==p and ctx.n('ClusterCount')[0]==meanmeta.n('N_Patients')[0],'FULL_FIT_DIMENSIONS_CHANGED')
 need(ctx.n('TargetCalibrationVerified')[0]==1 and ctx.n('AllCoefficientsCalibrated')[0]==0 and ctx.c('CalibrationDomain')==['FIXED_PREDECLARED_TARGET_SPAN']and ctx.c('StructuralCertificate')==['RAW_LITERAL_SUPPORT_V1'],'NATIVE_ALL_DELETION_CALIBRATION');need(new('si_status').c('cr2rc')==['PASS'],'NATIVE_KERNEL_STATUS')
 CB=new('si_spanbasis').mat();VR=new('si_spanrobust').mat();M=new('si_moment').mat();E=new('si_moment_error').mat();
 for role,value in [('si_spanbasis',CB),('si_spanrobust',VR),('si_moment',M),('si_moment_error',E)]:exact_binary64(value,getold(prefix+'_'+role+'.csv').mat(),'ACCEPTED_FULL_MATRIX_CHANGED')
 need(CB.shape==(h,p)and VR.shape==(h,h)and M.shape==E.shape==(dim,dim),'NATIVE_MATRIX_SHAPES');check_spd(VR,'ROBUST_COVARIANCE');need(np.isfinite(E).all()and(E>=0).all(),'MOMENT_ERROR_BOUNDS')
 us,sv,vt=np.linalg.svd(CB,full_matrices=False);need(sv[-1]>1e-6*sv[0],'SCORE_SPAN_RANK');CBplus=(vt.T/sv)@us.T
 basis=dense_long(new('si_basis'),'Parameter','ActiveColumn');bread=dense_long(new('si_bread'),'Row','Col');fullbread=basis@bread@basis.T
 close(basis.T@basis,np.eye(basis.shape[1]),'FITTED_BASIS_ORTHONORMAL',rtol=0,atol=2e-9);check_spd(bread,'FULL_FIT_BREAD',pd=True);close(CB,CB@basis@basis.T,'FULL_FIT_TARGET_ESTIMABILITY',rtol=2e-8,atol=1e-9);close((CB@basis)@bread@(CB@basis).T,np.eye(h),'FULL_FIT_REFERENCE_CALIBRATION',rtol=2e-8,atol=1e-9)
 covariance=dense_long(new('si_covariance'),'Row','Col');check_spd(covariance,'FULL_FIT_ROBUST_COVARIANCE');covariance_close(covariance,basis@(basis.T@covariance@basis)@basis.T,'FULL_FIT_COVARIANCE_SUPPORT');covariance_close(VR,CB@covariance@CB.T,'FULL_FIT_SPAN_COVARIANCE')
 envelope=ctx.n('RoundoffEnvelope')[0];oldctx=getold(prefix+'_si_context.csv');need(envelope==oldctx.n('RoundoffEnvelope')[0]and h==oldctx.n('SpanDimension')[0],'ORIGINAL_FULL_CONTEXT_CHANGED')
 oldcov=getold(job+'_covparms.csv');covlookup=dict(zip(oldcov.c('CovParm'),oldcov.n('Estimate')));need(set(covlookup)=={'Intercept','Residual'}and ctx.n('Tau2')[0]==covlookup['Intercept']and ctx.n('Sigma2')[0]==covlookup['Residual']and ctx.n('Alpha')[0]==.05,'ORIGINAL_WORKING_COVARIANCE_CHANGED')
 working=new('working_target');need(working.n('Tau2')[0]==ctx.n('Tau2')[0]and working.n('Sigma2')[0]==ctx.n('Sigma2')[0]and working.n('Alpha')[0]==.05 and working.n('ComponentCount')[0]==2 and working.n('RIComponents')[0]==working.n('ResidualComponents')[0]==1,'WORKING_TARGET_SCHEMA')
 reference_solution=new('si_solution');sx=np.zeros(p);sx[reference_solution.n('Parameter').astype(int)-1]=reference_solution.n('Estimate');close(sx,beta,'ORIGINAL_SOLUTION_CHANGED',rtol=0,atol=0)
 weights=new('si_scalar_weights');same(weights.n('TargetIndex'),np.arange(1,14426),'NATIVE_SCALAR_WEIGHT_KEYS');W=weights.mat();need(W.shape==(14425,h),'NATIVE_WEIGHT_DIMENSIONS');mapping.check_scalar_weight_mapping(W,targets@CBplus,lambda v,c:need(v,c));need(np.all(np.linalg.norm(targets-W@CB,axis=1)<=2e-8*np.linalg.norm(targets,axis=1)),'TARGET_OUTSIDE_SPAN')
 # Verify the stored error bounds using their native centers and radii and
 # directed decimal arithmetic when required.
 ct=new('certificate_context');fields=list(cert.CERTIFICATE_CONTEXT_CHARS+cert.CERTIFICATE_CONTEXT_NUMS)+['RunId','FitId','Scope'];context={k:(float(ct.n(k)[0])if k in cert.CERTIFICATE_CONTEXT_NUMS else ct.c(k)[0])for k in fields}
 tests=[{'TestIndex':i,'ConstraintIndices':list(range(1,n+1))}for i,n in[(1,4),(2,24)]]
 expected={'RunId':identity.c('RunId')[0],'FitId':identity.c('FitId')[0],'Scope':scope,'ConstructionSourceSHA256':ORIGINAL_CONSTRUCTION,'SpanDimension':h,'MomentDimension':dim,'TargetIndices':list(range(1,14426)),'Tests':tests}
 desc=cert.descriptor_from_context(context,target_indices=expected['TargetIndices'],tests=tests,expected=expected)
 rolemap={'moment_error':'si_moment_error','scalar_weights':'si_scalar_weights','scalar_certificate':'si_scalar_certificate','joint_weights':'joint_weights','joint_certificate':'joint_certificate'}
 tables={role:new(rolemap[role]).numeric_rows(cols)for role,(_,cols,count)in cert.schemas(desc).items()}
 replay=None # Check the archived scalar results before recomputing the selected scalar and joint tests.
 scalars={int(r['TargetIndex']):r for r in tables['scalar_certificate']};jcert={int(r['TestIndex']):r for r in tables['joint_certificate']}
 observed=[];role_counts={}
 for role,kind,count in [('levels',1,7205),('changes',2,7205),('within',3,5),('pairwise',4,10)]:
  t=new(role);need(len(t.rows)==count,'FINAL_ROLE_CARDINALITY');role_counts[role]=count
  for k in ['RunId','FitId','InputSnapshotId','CodeHash','JobID','ProfileId']:
   need(set(t.c(k))==set(identity.c(k)),'FINAL_ROLE_IDENTITY')
  for i in range(count):observed.append((t,i))
 order=np.argsort([t.n('TargetIndex')[i]for t,i in observed]);observed=[observed[i]for i in order]
 def field(k):return np.array([t.n(k)[i]for t,i in observed])
 same(np.column_stack([field(k)for k in keynames]),keys,'FINAL_TARGET_KEYS')
 inherited=inherited_scalar_proof(observed,new,getold,W,tables,job)
 subset_expected=dict(expected,TargetIndices=[FRESH_SCALAR]);subset_desc=cert.descriptor_from_context(context,target_indices=[FRESH_SCALAR],tests=tests,expected=subset_expected)
 subset_tables={k:([row for row in rows if int(row['TargetIndex'])==FRESH_SCALAR]if k in ['scalar_weights','scalar_certificate']else rows)for k,rows in tables.items()}
 replay=cert.validate_contractions(subset_desc,subset_tables,M,expected=subset_expected)
 zero=np.max(np.abs(targets),axis=1)==0;need(int(zero.sum())==5,'DETERMINISTIC_ZERO_COUNT');theta=targets@beta
 ia,ib=np.triu_indices(h);scale=np.sqrt(2-(ia==ib));variance=np.einsum('ij,jk,ik->i',W,VR,W);reference=np.sum(W*W,axis=1);den=np.empty(14425)
 den[:]=[scalars[i+1]['Denominator']for i in range(14425)]
 w=W[FRESH_SCALAR-1];v=scale*w[ia]*w[ib];den[FRESH_SCALAR-1]=float(v@M@v)
 unavailable=[];valid=[]
 for i,(t,j)in enumerate(observed):
  kind=int(keys[i,1]);targetid=('L_'if kind==1 else'C_')+f'{int(keys[i,2]):08d}'if kind in(1,2)else f'W_{int(keys[i,6])}'if kind==3 else f'P_{int(keys[i,6])}_{int(keys[i,7])}'
  need(t.c('TargetID')[j]=='MF1.'+targetid and t.c('OriginalTargetID')[j]==targetid and t.c('TargetRole')[j]==['LEVEL','CHANGE','WITHIN','PAIRWISE'][kind-1],'TARGET_LABELS')
  need(t.c('FamilyID')[j]==(job+'_HOLM10_V1_801e3333cc8c'if kind==4 else'NONE'),'NEW_FAMILY_ID')
  need(t.n('BaselineMinute')[j]==-60 and t.n('EndpointMinute')[j]==60,'TARGET_TIMES')
  need(t.c('CIAdjustment')[j]==('Deterministic zero'if zero[i]else'None: pointwise')and t.c('PAdjustment')[j]==('Holm within amended fixed family10'if kind==4 else'NONE'),'TARGET_ADJUSTMENT_LABEL')
  status=t.c('NumericStatus')[j];cs=t.n('ContrastStatus')[j]
  if zero[i]:
   need(status=='BASELINE_ZERO'and cs==2,'BASELINE_ZERO_STATUS')
   for f in ['Estimate','StdErr','Lower','Upper','Variance','ReferenceVariance']:need(t.n(f)[j]==0,'BASELINE_ZERO_VALUES')
   for f in ['DF','tValue','Probt']:need(math.isnan(t.n(f)[j]),'BASELINE_ZERO_NOT_INFERENCE')
  elif cs==4 and kind in(1,2):
   need(status=='MOMENT_PRECISION_UNRESOLVED'and availability.classify_native_certificate(scalars[i+1])=='PRECISION_UNRESOLVED','UNAVAILABLE_CERTIFICATE')
   for f in availability.UNCERTAINTY_FIELDS:need(math.isnan(t.n(f)[j]),'UNAVAILABLE_UNCERTAINTY_PRESENT')
   close(t.n('Estimate')[j],theta[i],'UNAVAILABLE_POINT',rtol=2e-7,atol=1e-9);unavailable.append(i)
  else:need(cs==0 and status=='COMPUTED'and scalars[i+1]['Resolved']==1,'SCALAR_DISPOSITION');valid.append(i)
 valid=np.array(valid,dtype=int);native=np.array([scalars[int(i)+1]['Denominator']for i in valid]);close(den[FRESH_SCALAR-1],scalars[FRESH_SCALAR]['Denominator'],'PRESPECIFIED_SCALAR_MOMENT',rtol=2e-7,atol=0)
 need(np.all(native>0)and np.all(variance[valid]>0)and np.all(reference[valid]>0),'SCALAR_GEOMETRY');df=reference[valid]**2/native;se=np.sqrt(variance[valid]);tv=theta[valid]/se;pv=2*stats.t.sf(np.abs(tv),df);crit=stats.t.ppf(.975,df)
 need(np.all(df>=1-1e-8)and np.all(df<=ctx.n('ClusterCount')[0]*(1+1e-8)),'SCALAR_DF_RANGE')
 for f,x in [('Estimate',theta[valid]),('StdErr',se),('DF',df),('tValue',tv),('Variance',variance[valid]),('ReferenceVariance',reference[valid])]:close(field(f)[valid],x,'SCALAR_'+f.upper(),rtol=2e-7,atol=1e-9)
 close(field('Probt')[valid],pv,'SCALAR_PROBABILITY',rtol=2e-7,atol=1e-10)
 for f,x in [('Lower',theta[valid]-crit*se),('Upper',theta[valid]+crit*se)]:close(field(f)[valid],x,'SCALAR_CI',rtol=2e-7,atol=2e-9*np.maximum.reduce([np.abs(theta[valid]),crit*se,np.full(len(valid),1e-6)]))
 pairs=new('pairwise');order=np.argsort(pairs.n('TargetIndex'));raw=pairs.n('Probt')[order];need(len(raw)==10 and np.isfinite(raw).all()and(raw>=0).all()and(raw<=1).all(),'TEN_RAW_P_REQUIRED');orderp=np.lexsort((pairs.n('TargetIndex')[order],raw));adj=np.empty(10);adj[orderp]=np.minimum(1,np.maximum.accumulate(raw[orderp]*np.arange(10,0,-1)));close(pairs.n('PValue_Holm')[order],adj,'HOLM_TEN',rtol=1e-12,atol=1e-15);need(set(pairs.c('PAdjustment'))=={'Holm within amended fixed family10'},'HOLM_LABEL')
 fam=new('family_plan');need(fam.c('FamilyID')==[job+'_HOLM10_V1_801e3333cc8c']and fam.c('FreezeStage')==['POST_START_AMENDMENT']and fam.n('PlanVersion')[0]==2,'AMENDED_FAMILY_IDENTITY')
 for f,n in [('PlannedCategories',5),('AvailableCategories',5),('PlannedPairs',10),('ActivePairs',10)]:same(fam.n(f),np.array([n]),'HOLM_FIXED_MEMBERSHIP')
 jd=new('joint_design');jr=new('joint');ra=new('joint_rank_audit');jw=new('joint_weights');joint_states=[]
 for test,C,label in [(1,endpoint,'MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY'),(2,whole,'MONDAY_FRIDAY_TRAJECTORY_INTERACTION')]:
  rows=np.flatnonzero(jd.n('TestIndex')==test);rows=rows[np.argsort(jd.n('ConstraintIndex')[rows])];same(jd.n('ConstraintIndex')[rows],np.arange(1,len(C)+1),'JOINT_KEYS');close(jd.mat('RBCX')[rows],C,'EXACT_NEW_NULL',rtol=2e-10,atol=1e-12)
  expected_categories=np.array([codemap[c]for c in range(3,7)]);expected_categories=expected_categories if test==1 else np.repeat(expected_categories,6);same(jd.n('CategoryIndex')[rows],expected_categories,'JOINT_ORIGINAL_CATEGORY_MAP');same(jd.n('AnchorIndex')[rows],np.full(4,np.nan)if test==1 else np.tile([2,3,4,6,7,8],4),'JOINT_EXACT_ANCHORS')
  w=C@CBplus;need(np.all(np.linalg.norm(C-w@CB,axis=1)<=2e-8*np.linalg.norm(C,axis=1)),'JOINT_SPAN');sc=np.linalg.norm(w,axis=1);need((sc>0).all(),'JOINT_ZERO_ROW');normalized=w/sc[:,None];u,s,vt=np.linalg.svd(normalized,full_matrices=False);rank=int(np.sum(s>1e-10*s[0]));ri=np.flatnonzero(ra.n('TestIndex')==test);need(len(ri)==1 and ra.n('DerivedRank')[ri[0]]==rank and ra.n('WrittenRows')[ri[0]]==len(C)and ra.n('ReferenceAdmissible')[ri[0]]==int(s[-1]>1e-6*s[0]),'DERIVED_NULL_RANK');need(rank==len(C)and s[-1]>1e-6*s[0],'REDUNDANT_NULL_REFUSED')
  wi=np.flatnonzero(jw.n('TestIndex')==test);wi=wi[np.argsort(jw.n('ConstraintIndex')[wi])];nativew=jw.mat()[wi];close(nativew@nativew.T,np.eye(rank),'JOINT_REFERENCE_CALIBRATION',rtol=0,atol=2e-8);need(np.all(np.linalg.norm(normalized-normalized@nativew.T@nativew,axis=1)<=2e-8*np.linalg.norm(normalized,axis=1)),'NATIVE_JOINT_NULL_CHANGED')
  sq=packed_transform(nativew);dm=2*float(np.sum(sq*(sq@M)));c=jcert[test];idx=np.flatnonzero(jr.n('TestIndex')==test);need(len(idx)==1,'JOINT_OUTPUT_COUNT');j=int(idx[0]);need(jr.c('TestRole')[j]==label,'JOINT_NULL_LABEL');close(np.array([jr.n(f)[j]for f in ['Q','DF1','MomentDenominator']]),np.array([rank,rank,c['Denominator']]),'JOINT_DIMENSIONS',rtol=2e-6,atol=1e-9)
  if c['Resolved']==1:close(dm,c['Denominator'],'JOINT_MOMENT',rtol=2e-6,atol=0)
  d=c['Denominator'];nu=rank*(rank+1)/d if d>0 else math.nan;df2=nu-rank+1
  if d>0:close(np.array([jr.n('Nu')[j],jr.n('DF2')[j]]),np.array([nu,df2]),'JOINT_DF',rtol=2e-6,atol=1e-9)
  state=jr.c('NumericStatus')[j];js=jr.n('JointStatus')[j]
  if c['Resolved']!=1:need(js==4 and state=='MOMENT_PRECISION_UNRESOLVED','JOINT_UNAVAILABLE');need(all(math.isnan(jr.n(f)[j])for f in['Wald','FValue','ProbF']),'JOINT_UNAVAILABLE_VALUES')
  else:
   obs=nativew@VR@nativew.T;check_spd(obs,'JOINT_OBSERVED_COVARIANCE',pd=True);theta_joint=nativew@CB@beta;wald=float(theta_joint@np.linalg.solve(obs,theta_joint));close(jr.n('Wald')[j],wald,'JOINT_WALD',rtol=2e-6,atol=1e-9)
   if c['DF2Sign']in(0,2):need(js==5 and state=='DF2_SIGN_UNRESOLVED','JOINT_SIGN_UNAVAILABLE')
   elif df2<=0:need(c['DF2Sign']==-1 and js==2 and state=='INSUFFICIENT_EFFECTIVE_DF','JOINT_DF_UNAVAILABLE')
   else:
    need(c['DF2Sign']==1 and js==int(df2<4)and state==('LOW_EFFECTIVE_DF'if df2<4 else'COMPUTED'),'JOINT_STATUS');fv=df2*wald/(nu*rank);close(jr.n('FValue')[j],fv,'JOINT_F',rtol=2e-6,atol=1e-10);close(jr.n('ProbF')[j],stats.f.sf(fv,rank,df2),'JOINT_P',rtol=2e-6,atol=1e-10)
   if c['DF2Sign']in(0,2)or df2<=0:need(math.isnan(jr.n('FValue')[j])and math.isnan(jr.n('ProbF')[j]),'JOINT_UNAVAILABLE_INFERENCE')
  joint_states.append({'TestIndex':test,'Null':label,'WrittenRows':len(C),'DerivedRank':rank,'Status':state})
 parity=dict(inherited,FullMatricesExactlyEqual=True,FullBasisRetained=True,SpanTransform='IDENTITY',OriginalAcceptedProof=accepted_proof)
 role_dispositions={role:{'Status':'VALIDATED','RequestedTargets':count,'ComputedTargets':count,'UnavailableTargets':0}for role,count in role_counts.items()}
 for role,kind in [('levels',1),('changes',2)]:
  n=sum(int(keys[i,1])==kind for i in unavailable);role_dispositions[role].update(Status='VALIDATED_WITH_EXPLICIT_UNAVAILABLE_TARGETS'if n else'VALIDATED',ComputedTargets=role_counts[role]-n-(5 if role=='changes'else 0),UnavailableTargets=n,DeterministicZeroTargets=5 if role=='changes'else 0)
 for item,role in zip(joint_states,['endpoint_joint','trajectory_joint']):role_dispositions[role]={'Status':item['Status'],'ValidatedDisposition':True,'DerivedRank':item['DerivedRank']}
 profile_refs=[{'Path':f['Path'],'SHA256':f['SHA256']}for f in case['Files']if Path(f['Path']).name.lower()==(job+'_profile.csv').lower()]
 need(len(profile_refs)==1,'ORIGINAL_PROFILE_BINDING_REQUIRED')
 return {'RoleDispositions':role_dispositions,'Status':'PASS','JobID':job,
         'CompleteSupportedCompanion':not unavailable and all(j['Status']in ['COMPUTED','LOW_EFFECTIVE_DF']for j in joint_states),
         'RequestedTargets':14425,'RoleCounts':role_counts,'DeterministicZeros':5,
         'ComputedScalarTargets':len(valid),'PrecisionUnavailableScalarTargets':len(unavailable),
         'JointDispositions':joint_states,
         'CertificateReplay':{k:v for k,v in replay.items()if k not in ['NativeUnresolvedScalarTargets','NativeUnresolvedDecimalVerified','NativeUnresolvedReplayResolves']},
         'AcceptedReferenceComparison':parity,'Files':[t.metadata()for t in loaded.values()],
         'ReferenceProfileBinding':profile_refs,'FullFitDenominatorsPreserved':True}

