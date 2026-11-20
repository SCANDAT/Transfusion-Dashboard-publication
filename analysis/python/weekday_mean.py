"""Fixed-working-covariance coefficient correction from retained QR blocks.

The fitted design rank and working variance parameters remain fixed. Apply
only to the declared cases after the required residual-consistency failure.
The represented coefficient increment is used in every residual derivative.
"""
import numpy as np
from scipy import linalg

def norm(x): return float(np.linalg.norm(x))

class Rejected(ValueError):
    pass

def need(ok, code):
    if not ok:
        raise Rejected(code)

def whiten(q,m,tau,sigma):
    n=float((q.T@q).item())
    need(n>0 and tau>=0 and sigma>0,'WORKING_VARIANCE_OR_Q1_INVALID')
    mean=q@(q.T@m)/n
    return (m-mean)/np.sqrt(sigma)+mean/np.sqrt(sigma+n*tau)


def full_retained_scale(K,corrected_residual,candidate,tau,sigma):
    residual=whiten(K[:,[0]],corrected_residual,tau,sigma)
    fitted=whiten(K[:,[0]],K[:,1:]@candidate,tau,sigma)
    return residual,norm(residual)+norm(fitted)


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

