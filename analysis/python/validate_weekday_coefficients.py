"""Independent replay of fixed-covariance coefficient and residual derivatives.

Validate the proposed coefficient solution and residuals using the retained
working-model summaries. The original fit supplies the variance parameters.
"""
from pathlib import Path
import hashlib, json, re, struct
import numpy as np
from scipy import linalg
from threadpoolctl import threadpool_limits
import weekday_validation_core as base

class CandidateRejected(ValueError): pass

def need(ok,code):
    if not ok:raise CandidateRejected(code)

def checked(item):
    p=Path(item['Path'])
    need(p.is_file() and not p.is_symlink() and re.fullmatch('[0-9a-f]{64}',item['SHA256']) is not None and base.sha(p)==item['SHA256'],'CANDIDATE_INPUT_PIN_CHANGED')
    return p


def whiten(q,m,tau,sigma):
    n=float((q.T@q).item())
    need(n>0 and tau>=0 and sigma>0,'WORKING_VARIANCE_OR_Q1_INVALID')
    mean=q@(q.T@m)/n
    return (m-mean)/np.sqrt(sigma)+mean/np.sqrt(sigma+n*tau)

def reference_from_blocks(blocks,E,beta,tau,sigma):
    """Single streaming QR of [WX E, Wr, W(r+X beta), WX beta_complement]."""
    p,r=E.shape
    need(0<r<=p and beta.shape==(p,1),'FIXED_RANK_SCHEMA')
    width=r+3
    accumulator=np.zeros((width,width))
    active_beta=E.T@beta
    complement=beta-E@active_beta
    omitted_fit_ss=0.;saved_fit_ss=0.;blocks_seen=0
    for q,X,residual in blocks:
        need(q.ndim==X.ndim==residual.ndim==2 and q.shape==residual.shape
             and q.shape[1]==1 and X.shape==(len(q),p)
             and np.isfinite(q).all() and np.isfinite(X).all()
             and np.isfinite(residual).all(),'RETAINED_BLOCK_SCHEMA')
        WX=whiten(q,X,tau,sigma)
        Z=WX@E
        Wr=whiten(q,residual,tau,sigma)
        Wy=whiten(q,residual+X@beta,tau,sigma)
        omitted=WX@complement
        stack=np.vstack((accumulator,np.column_stack((Z,Wr,Wy,omitted))))
        accumulator=linalg.qr(stack,mode='r',overwrite_a=True,check_finite=False)[0][:width,:].copy()
        omitted_fit_ss+=float(np.sum(omitted*omitted))
        fitted=WX@beta;saved_fit_ss+=float(np.sum(fitted*fitted))
        blocks_seen+=1
    need(blocks_seen>0,'NO_RETAINED_BLOCKS')
    triangular=accumulator[:r,:r]
    need(np.isfinite(accumulator).all() and np.all(np.diag(triangular)!=0),
         'FIXED_ACTIVE_RANK_UNRESOLVED')
    solved=linalg.solve_triangular(triangular,accumulator[:r,r:],lower=False,check_finite=False)
    d,response,omitted_solution=solved[:,[0]],solved[:,[1]],solved[:,[2]]
    closure=response-active_beta-d-omitted_solution
    closure_scale=np.abs(response)+np.abs(active_beta)+np.abs(d)+np.abs(omitted_solution)
    need(np.isfinite(solved).all(),'NONFINITE_REFERENCE')
    return {'DeltaActive':d,'ResponseActiveSolution':response,
            'OmittedFitActiveSolution':omitted_solution,'ResponseClosureResidual':closure,
            'ResponseClosureScale':closure_scale,'TriangularDesign':triangular,
            'FixedRankPreserved':True,'BlocksSeen':blocks_seen,
            'OmittedFitNorm':np.sqrt(omitted_fit_ss),'SavedFitNorm':np.sqrt(saved_fit_ss)}

def candidate_solution(beta,E,active_correction):
    beta=np.asarray(beta,dtype=float)
    E=np.asarray(E,dtype=float)
    d=np.asarray(active_correction,dtype=float)
    need(beta.ndim==2 and beta.shape[1]==1 and E.ndim==2
         and E.shape[0]==len(beta) and d.shape==(E.shape[1],1),
         'CANDIDATE_COORDINATE_SCHEMA')
    need(all(np.isfinite(x).all() for x in [beta,E,d]),'FINITE_CANDIDATE_INPUTS')
    candidate=beta+E@d
    # Subtract the original coefficients to obtain the change after floating-point rounding.
    applied=candidate-beta
    need(np.isfinite(candidate).all() and np.isfinite(applied).all(),'FINITE_CANDIDATE_OUTPUTS')
    return candidate,applied

def corrected_qr_block(block,applied):
    """Schema: Cluster, Row, NObs, K0, RBCX1..p, Cross. Return a fresh block."""
    original=np.asarray(block,dtype=float)
    applied=np.asarray(applied,dtype=float)
    need(applied.ndim==2 and applied.shape[1]==1,'APPLIED_CHANGE_SCHEMA')
    p=len(applied)
    need(original.ndim==2 and original.shape[1]==p+5
         and np.isfinite(original).all() and np.isfinite(applied).all(),
         'RETAINED_QR_BLOCK_SCHEMA')
    candidate=original.copy()
    candidate[:,[-1]]=original[:,[-1]]-original[:,4:4+p]@applied
    need(np.isfinite(candidate).all(),'FINITE_CORRECTED_RESIDUAL')
    # All design, QR row coordinates and row/count keys remain bitwise unchanged.
    need(np.array_equal(candidate[:,:-1],original[:,:-1]),'IMMUTABLE_QR_COLUMNS_CHANGED')
    return candidate

def candidate_trajectory(score,category,time,beta_candidate):
    """All original scoring rows/categories, including weekends; no subset selection."""
    score=np.ascontiguousarray(score,dtype=float)
    category=np.asarray(category)
    time=np.asarray(time,dtype=float)
    beta=np.asarray(beta_candidate,dtype=float)
    need(score.ndim==2 and beta.shape==(score.shape[1],1)
         and category.shape==time.shape==(len(score),)
         and np.isfinite(score).all() and np.isfinite(time).all()
         and np.isfinite(beta).all(),'ORIGINAL_TRAJECTORY_SCHEMA')
    predicted=score@beta
    change=np.empty_like(predicted)
    for value in np.unique(category):
        rows=np.flatnonzero(category==value)
        base=rows[time[rows]==-60]
        need(len(base)==1,'EXACT_ORIGINAL_BASELINE_REQUIRED')
        change[rows]=(score[rows]-score[base[0]])@beta
    need(np.isfinite(predicted).all() and np.isfinite(change).all(),'FINITE_CANDIDATE_TRAJECTORY')
    return predicted,change

def hex_values(value):
    return [struct.pack('>d',float(x)).hex().upper() for x in np.asarray(value).reshape(-1)]

def candidate_arrays(transform,original,basis,active,lineage):
    candidate,applied=transform.candidate_solution(original,basis,active)
    for name,value in [('OriginalBetaHex',original),('CandidateBetaHex',candidate),('AppliedChangeHex',applied)]:
        need(isinstance(lineage.get(name),list) and lineage[name]==hex_values(value),'CANDIDATE_EXACT_'+name.upper())
    return candidate.reshape(-1),applied.reshape(-1)

def bitwise_equal(a,b):
    a=np.ascontiguousarray(a,dtype=np.float64);b=np.ascontiguousarray(b,dtype=np.float64)
    return a.shape==b.shape and a.tobytes()==b.tobytes()

def verify_qr_arrays(original,candidate,applied,transform):
    p=len(applied);original=np.asarray(original);candidate=np.asarray(candidate)
    need(original.shape==candidate.shape and original.ndim==2 and original.shape[1]==p+5
         and len(original)>0 and len(original)%(p+2)==0,'ALL_CLUSTER_CANDIDATE_QR_SCHEMA')
    need(bitwise_equal(original[:,:-1],candidate[:,:-1]),'CANDIDATE_QR_GEOMETRY_OR_KEYS_CHANGED')
    for start in range(0,len(original),p+2):
        want=transform.corrected_qr_block(original[start:start+p+2],applied.reshape(-1,1))
        need(bitwise_equal(want,candidate[start:start+p+2]),'CANDIDATE_QR_RESIDUAL_TRANSFORM_MISMATCH')

def verify_native_derivatives(d,bindings,base,context,transform,job):
    import pyreadstat
    files=bindings['Cases'][0]['Files'];exchange=d['ExchangeFiles'];p=len(context['Beta'])
    qr=[x for x in files if Path(x['Path']).name.lower()==('c'+job[1:]+'_cs_qr.sas7bdat')]
    need(len(qr)==1,'ORIGINAL_QR_REFERENCE_REQUIRED')
    original_qr={k:qr[0][k]for k in ['Path','SHA256']}
    need(Path(original_qr['Path']).resolve()!=Path(exchange['cs_qr']['Path']).resolve(),'ORIGINAL_QR_REPLACEMENT_FORBIDDEN')
    columns=['Cluster','Row','NObs','K0']+['RBCX'+str(i+1)for i in range(p)]+['Cross']
    a,am=pyreadstat.read_sas7bdat(checked(original_qr),usecols=columns)
    b,bm=pyreadstat.read_sas7bdat(checked(exchange['cs_qr']),usecols=columns)
    need(am.column_names==bm.column_names==columns,'CANDIDATE_QR_COLUMNS_CHANGED')
    verify_qr_arrays(a.to_numpy(dtype=float),b.to_numpy(dtype=float),context['AppliedChange'],transform)
    del a,b
    def native(role):return pyreadstat.read_sas7bdat(checked(exchange[role]))[0]
    cs=native('cs_solution');model=native('model_solution')
    need({'Parameter','Estimate'}<=set(cs.columns) and {'Effect','Estimate'}<=set(model.columns),
         'CANDIDATE_NATIVE_SOLUTION_COLUMNS')
    need(len(cs)==len(model)==p and np.array_equal(np.sort(cs['Parameter'].to_numpy()),np.arange(1,p+1)),
         'CANDIDATE_NATIVE_SOLUTION_KEYS')
    csbeta=cs.sort_values('Parameter')['Estimate'].to_numpy(dtype=float)
    indexed={}
    for name,value in zip(model['Effect'],model['Estimate']):
        match=re.fullmatch(r'RBCX([1-9][0-9]*)',str(name).strip(),re.I)
        need(match is not None,'CANDIDATE_MODEL_EFFECT_SCHEMA');i=int(match[1]);need(1<=i<=p and i not in indexed,'CANDIDATE_MODEL_EFFECT_KEYS');indexed[i]=float(value)
    need(bitwise_equal(csbeta,context['Beta']) and bitwise_equal(np.array([indexed[i]for i in range(1,p+1)]),context['Beta']),
         'CANDIDATE_NATIVE_SOLUTION_VALUE_CHANGED')
    need(not {'StdErr','DF','tValue','Probt'}&set(model.columns),'STALE_WORKING_SOLUTION_UNCERTAINTY')
    old=base.original_loader(bindings['Cases'][0]);score=old((job+'_score_design.csv'));trajectory=old((job+'_trajectory.csv'))
    tx=score.mat('RBCX');grid=score.n('GridID');cat=score.n('CategoryIndex');tm=score.n('TimeFromTransfusion')
    need(len(set(grid))==len(grid),'ORIGINAL_SCORE_GRID_KEYS')
    pred,change=transform.candidate_trajectory(tx,cat,tm,context['Beta'].reshape(-1,1))
    table=native('model_trajectory')
    need({'GridID','CategoryIndex','TimeFromTransfusion','Predicted','Delta'}<=set(table.columns)
         and len(table)==len(grid) and len(set(table['GridID']))==len(grid),'CANDIDATE_TRAJECTORY_KEYS')
    need(not {'StdErr','Lower','Upper'}&set(table.columns),'STALE_WORKING_TRAJECTORY_UNCERTAINTY')
    order={x:i for i,x in enumerate(grid)}
    need(set(table['GridID'])==set(grid)==set(trajectory.n('GridID')),'ALL_ORIGINAL_TRAJECTORY_ROWS_REQUIRED')
    ix=np.array([order[x]for x in table['GridID']],dtype=int)
    need(np.array_equal(table['CategoryIndex'].to_numpy(),cat[ix]) and np.array_equal(table['TimeFromTransfusion'].to_numpy(),tm[ix]),'CANDIDATE_TRAJECTORY_MAPPING_CHANGED')
    old_order={x:i for i,x in enumerate(trajectory.n('GridID'))}
    old_ix=np.array([old_order[x]for x in table['GridID']],dtype=int)
    for field in ['CategoryCode','BaselineMinute']:
        need(field in table.columns and np.array_equal(table[field].to_numpy(),trajectory.n(field)[old_ix]),'CANDIDATE_TRAJECTORY_CATEGORY_OR_BASELINE_CHANGED')
    need(bitwise_equal(table['Predicted'].to_numpy(dtype=float),pred[ix,0]) and bitwise_equal(table['Delta'].to_numpy(dtype=float),change[ix,0]),'CANDIDATE_TRAJECTORY_VALUE_CHANGED')
    checked(original_qr)
    return {'AllRetainedQRBlocksVerified':True,'AllNativeSolutionsVerified':True,'AllOriginalTrajectoryRowsVerified':True,'StaleWorkingUncertaintyExcluded':True}
