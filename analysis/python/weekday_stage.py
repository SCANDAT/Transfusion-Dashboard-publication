"""Create separate fixed-covariance coefficient and residual inputs.

Use the retained model summaries and keep their variance parameters fixed.
"""
from pathlib import Path
import csv
import hashlib
import json
import re
import struct
import numpy as np
from threadpoolctl import threadpool_limits
from weekday_mean import (need, Rejected, reference_from_blocks, candidate_solution,
                          corrected_qr_block, candidate_trajectory)


def file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def hex64(value):
    return struct.pack('>d', float(value)).hex().upper()


def write_csv(path, headers, rows):
    with Path(path).open('x', encoding='ascii', newline='') as stream:
        writer = csv.writer(stream, lineterminator='\n')
        writer.writerow(headers)
        writer.writerows(rows)


def stage_candidate(*, inputs, output, job_id, candidate_id, failure_reason,
                    method, eligible_jobs):
    """Write new derivative inputs only after a bound eligible failure.

    inputs maps basis/beta/params/global_factor/qr/score to Path and SHA256.
    Every input is checked before and after use. The caller separately binds
    these files to the validated original working model and native failure.
    """
    import pyreadstat
    need(method == 'FIXED_COVARIANCE_CORRECTION' and job_id in eligible_jobs
         and re.fullmatch(r'M[0-9]{4}', job_id)
         and failure_reason == 'EXCLUSIVE_NATIVE_RESIDUAL_MISMATCH',
         'DECLARED_RESIDUAL_MISMATCH_CASE_REQUIRED')
    need(re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', candidate_id) is not None,
         'CANDIDATE_ID_REQUIRED')
    required = {'basis','beta','params','global_factor','qr','score'}
    need(set(inputs) == required, 'CANDIDATE_INPUT_ROLES')
    def checked(key):
        ref = inputs[key]; path = Path(ref['Path'])
        need(path.is_file() and not path.is_symlink()
             and re.fullmatch('[0-9a-f]{64}',ref['SHA256'])
             and file_hash(path) == ref['SHA256'], 'CANDIDATE_INPUT_HASH')
        return path
    def native(key, columns=None):
        table, metadata = pyreadstat.read_sas7bdat(checked(key), usecols=columns)
        if columns is not None:
            need(metadata.column_names == columns, 'RETAINED_COLUMN_ORDER')
        return table
    b = native('basis')
    ri,ci = b['Parameter'].to_numpy(),b['ActiveColumn'].to_numpy()
    need(len(b)>0 and np.isfinite(ri).all() and np.isfinite(ci).all()
         and np.all(ri>=1) and np.all(ci>=1)
         and np.all(ri==np.floor(ri)) and np.all(ci==np.floor(ci)), 'BASIS_KEYS')
    p,r = int(ri.max()),int(ci.max())
    need(0<r<=p<=200 and len(set(zip(ri,ci)))==p*r, 'BASIS_DIMENSIONS')
    E=np.full((p,r),np.nan);E[ri.astype(int)-1,ci.astype(int)-1]=b['Value']
    beta_table=native('beta').sort_values('Parameter')
    need(np.array_equal(beta_table['Parameter'],np.arange(1,p+1)), 'BETA_KEYS')
    beta=beta_table['Estimate'].to_numpy(dtype=float).reshape(p,1)
    params=native('params')
    need(len(params)==1 and params['FittedRank'].iloc[0]==r
         and params['ParameterCount'].iloc[0]==p, 'FIXED_PARAMETER_SCHEMA')
    tau=float(params['Tau2'].iloc[0]);sigma=float(params['Sigma2'].iloc[0])
    need(np.isfinite(E).all() and np.isfinite(beta).all()
         and tau>=0 and sigma>0, 'FINITE_FIXED_PARAMETERS')
    g=native('global_factor');gr=g['Row'].to_numpy();gc=g['Column'].to_numpy()
    need(len(g)==p*p and len(set(zip(gr,gc)))==p*p
         and np.array_equal(np.unique(gr),np.arange(1,p+1))
         and np.array_equal(np.unique(gc),np.arange(1,p+1)), 'GLOBAL_FACTOR_KEYS')
    global_factor=np.full((p,p),np.nan)
    global_factor[gr.astype(int)-1,gc.astype(int)-1]=g['Value']
    columns=['Cluster','Row','NObs','K0']+['RBCX'+str(i+1)for i in range(p)]+['Cross']
    qr=native('qr',columns).to_numpy(dtype=float,copy=False)
    need(len(qr)>0 and len(qr)%(p+2)==0 and np.isfinite(qr).all(), 'RETAINED_QR_SCHEMA')
    def blocks():
        for i in range(len(qr)//(p+2)):
            block=qr[i*(p+2):(i+1)*(p+2)];nobs=block[0,2]
            need(np.all(block[:,0]==i+1) and np.array_equal(block[:,1],np.arange(1,p+3))
                 and np.all(block[:,2]==nobs) and nobs>=1 and nobs==np.floor(nobs),
                 'RETAINED_QR_BLOCK_KEYS')
            q=block[:,[3]]
            need(abs(float((q.T@q).item())-nobs)<=128*np.finfo(float).eps*(p+2)*nobs,
                 'RETAINED_QR_INTERCEPT_COUNT')
            yield q,block[:,4:4+p],block[:,[-1]]
    with threadpool_limits(limits=1):
        reference=reference_from_blocks(blocks(),E,beta,tau,sigma)
        d=reference['DeltaActive']
        tiny=np.finfo(float).tiny
        need(np.all(np.abs(reference['ResponseClosureResidual'])<=2e-8*np.maximum(
             reference['ResponseClosureScale'],tiny)), 'FIXED_RESPONSE_CLOSURE')
        Q=reference['TriangularDesign']; G=global_factor@E
        qgram=Q.T@Q;ggram=G.T@G
        need(np.linalg.norm(qgram-ggram)<=2e-8*max(np.linalg.norm(qgram),np.linalg.norm(ggram),tiny),
             'INDEPENDENT_RETAINED_DESIGN_GRAM')
        candidate,applied=candidate_solution(beta,E,d)
        score=native('score')
        X=score[['RBCX'+str(i+1)for i in range(p)]].to_numpy(dtype=float)
        category=score['CategoryIndex'].to_numpy();time=score['TimeFromTransfusion'].to_numpy(dtype=float)
        grid=score['GridID'].to_numpy();codes=score['CategoryCode'].to_numpy()
        need(len(set(grid))==len(grid) and np.isfinite(category).all() and np.isfinite(codes).all(),
             'ORIGINAL_SCORE_KEYS')
        predicted,change=candidate_trajectory(X,category,time,candidate)
    for key in inputs: checked(key)
    output=Path(output);need(not output.exists(),'FRESH_CANDIDATE_DIRECTORY_REQUIRED')
    output.mkdir()
    for name in ['exchange','models','saved']:(output/name).mkdir()
    decimal=lambda x:format(float(x),'.17g')
    vector=output/'exchange/candidate_vector.csv'
    write_csv(vector,['Parameter','OriginalBeta','CandidateBeta','AppliedChange','OriginalHex','CandidateHex','AppliedHex'],
        ([i+1,decimal(beta[i,0]),decimal(candidate[i,0]),decimal(applied[i,0]),hex64(beta[i,0]),hex64(candidate[i,0]),hex64(applied[i,0])]for i in range(p)))
    def residual_rows():
        with threadpool_limits(limits=1):
            for i in range(len(qr)//(p+2)):
                block=qr[i*(p+2):(i+1)*(p+2)];new=corrected_qr_block(block,applied)
                for old,row in zip(block,new):
                    yield [int(old[0]),int(old[1]),decimal(old[-1]),decimal(row[-1]),hex64(old[-1]),hex64(row[-1])]
    rhs=output/'exchange/candidate_rhs.csv'
    write_csv(rhs,['Cluster','Row','OriginalCross','CandidateCross','OriginalHex','CandidateHex'],residual_rows())
    trajectory=output/'exchange/candidate_trajectory.csv'
    write_csv(trajectory,['GridID','CategoryIndex','CategoryCode','TimeFromTransfusion','Predicted','Delta','PredictedHex','DeltaHex'],
        ([int(grid[i]),int(category[i]),int(codes[i]),decimal(time[i]),decimal(predicted[i,0]),decimal(change[i,0]),hex64(predicted[i,0]),hex64(change[i,0])]for i in range(len(grid))))
    for key in inputs: checked(key)
    reference_values={key:value.tolist() if isinstance(value,np.ndarray) else value for key,value in reference.items()}
    reference_file=output/'reference.json'
    reference_file.write_text(json.dumps({'Protocol':'RETAINED_QR_FIXED_COVARIANCE_REFERENCE_V1',
        'JobID':job_id,'InputBindings':inputs,'SourceSHA256':file_hash(Path(__file__).with_name('weekday_mean.py')),
        'Values':reference_values},sort_keys=True,allow_nan=False)+'\n',encoding='utf-8')
    lineage={'Protocol':'FIXED_COVARIANCE_MEAN_DERIVATIVE_V1','JobID':job_id,'CandidateMeanID':candidate_id,
             'ParentInputs':inputs,'IndependentReference':{'Path':str(reference_file),'SHA256':file_hash(reference_file)},'OriginalBetaHex':[hex64(x)for x in beta[:,0]],
             'CandidateBetaHex':[hex64(x)for x in candidate[:,0]],'AppliedChangeHex':[hex64(x)for x in applied[:,0]],
             'FixedRank':r,'WorkingCovarianceChanged':False,'OriginalArchiveChanged':False,
             'ExchangeFiles':{name:{'Path':str(path),'SHA256':file_hash(path)}for name,path in
               [('Vector',vector),('ResidualRHS',rhs),('Trajectory',trajectory)]},
             'ScientificValidation':'PENDING'}
    (output/'lineage.json').write_text(json.dumps(lineage,sort_keys=True,allow_nan=False)+'\n',encoding='utf-8')
    return lineage
