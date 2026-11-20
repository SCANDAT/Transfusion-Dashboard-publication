"""Compare effect estimates and uncertainty from the same retained fit."""
import csv, math, re
from pathlib import Path
import numpy as np
from exact_numeric import decode_number
from validate_cr2_white_archive import state, need
import scalar_availability as availability
PROTOCOL = 'RBC_SAME_FIT_INFERENCE_COMPARISON_V1'
WORKING = ('identity', 'solution', 'covparms', 'score_design', 'trajectory', 'within_changes', 'pairwise')
WHITE = ('identity', 'si_solution', 'working_target', 'target_design', 'levels', 'changes', 'within', 'pairwise')

def _number(value):
    return decode_number(value, allow_legacy=True, allow_missing=False) if isinstance(value, str) else float(value)

def _missing(value):
    if not isinstance(value, str):
        return False
    try:
        return math.isnan(decode_number(value, allow_legacy=True, allow_missing=True))
    except ValueError:
        return False

def _uncertainty_unavailable(row, policy):
    """True only for an explicitly uncertainty-unavailable white row under LCPU_V1.
    Its point estimate is still compared; every uncertainty cell must be missing."""
    if row.get('numericstatus') != availability.UNAVAILABLE_REASON:
        return False
    need(policy == availability.LCPU_V1, 'SAME_FIT_UNAVAILABLE_NOT_PERMITTED')
    need(all((_missing(row.get(f.casefold())) for f in availability.UNCERTAINTY_FIELDS)), 'SAME_FIT_UNAVAILABLE_UNCERTAINTY_PRESENT')
    return True

def compare(working_dir, job, white_dir, prefix, expected, *, scalar_policy=None):
    """scalar_policy: trusted bound policy (None/STRICT = historical behaviour)."""
    try:
        policy = availability.policy(scalar_policy)
    except availability.AvailabilityRejected:
        need(False, 'SAME_FIT_POLICY_INVALID')
    need(bool(re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,11}', job)) and bool(re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,8}', prefix)))
    tracked = {}

    def rows(folder, name, role, allowed):
        need(role in allowed)
        p = Path(folder) / (name + '_' + role + '.csv')
        before = state(p)
        with p.open(encoding='utf-8-sig', newline='') as f:
            rr = [{k.casefold(): v for k, v in r.items()} for r in csv.DictReader(f)]
        need(state(p) == before)
        tracked[p] = before
        for r in rr:
            need(all((r[k.casefold()] == expected[k] for k in ('RunId', 'AnalysisSpecId', 'CohortMode', 'PopulationId', 'FitId', 'InputSnapshotId', 'CodeHash', 'ConfigHash', 'DesignId', 'ProfileId', 'JobID'))))
        return rr
    w = lambda role: rows(working_dir, job, role, WORKING)
    c = lambda role: rows(white_dir, prefix, role, WHITE)
    wi = w('identity')
    ci = c('identity')
    need(len(wi) == len(ci) == 1)
    need(wi[0]['inferencestatus'] == 'MODEL_BASED_CANDIDATE' and ci[0]['covariancemethod'] == 'GLS_WHITENED_CR2' and (ci[0]['calibrationdomain'] == 'FIXED_PREDECLARED_TARGET_SPAN'))
    sol = sorted(w('solution'), key=lambda r: int(r['effect'][4:]))
    cs = sorted(c('si_solution'), key=lambda r: int(_number(r['parameter'])))
    beta = np.array([_number(r['estimate']) for r in sol])
    cbeta = np.array([_number(r['estimate']) for r in cs])
    p = len(beta)
    need([r['effect'].upper() for r in sol] == ['RBCX' + str(i) for i in range(1, p + 1)])
    need(np.array_equal(beta, cbeta), 'SAME_FIT_COEFFICIENTS_CHANGED')
    cp = {r['covparm'].casefold(): _number(r['estimate']) for r in w('covparms')}
    wt = c('working_target')
    need(len(wt) == 1)
    need(cp['intercept'] == _number(wt[0]['tau2']) and cp['residual'] == _number(wt[0]['sigma2']), 'SAME_FIT_WORKING_VARIANCE_CHANGED')
    grid = sorted(w('score_design'), key=lambda r: int(_number(r['gridid'])))
    target = sorted(c('target_design'), key=lambda r: int(_number(r['targetindex'])))
    X = np.array([[_number(r['rbcx' + str(i)]) for i in range(1, p + 1)] for r in grid])
    C = np.array([[_number(r['rbcx' + str(i)]) for i in range(1, p + 1)] for r in target])
    n = len(X)
    need(np.array_equal(X, C[:n]), 'SAME_FIT_PROFILE_CHANGED')
    coordinate = {(int(_number(r['categoryindex'])), int(_number(r['timefromtransfusion']))): i for i, r in enumerate(grid)}
    need(len(coordinate) == n)
    delta = X.copy()
    for i, r in enumerate(grid):
        delta[i] -= X[coordinate[int(_number(r['categoryindex'])), -60]]
    exact_exchange = wi[0]['bindingversion'].startswith('H') and ci[0]['bindingversion'].startswith('H')
    if exact_exchange:
        need(np.array_equal(delta, C[n:2 * n]), 'SAME_FIT_CHANGE_DESIGN_CHANGED')
    else:
        baselines = np.array([X[coordinate[int(_number(r['categoryindex'])), -60]] for r in grid])
        bound = 8 * np.finfo(float).eps * (np.abs(X) + np.abs(baselines)) + 8 * np.nextafter(0.0, 1.0)
        need(np.all(np.abs(delta - C[n:2 * n]) <= bound) and np.array_equal(delta == 0, C[n:2 * n] == 0), 'SAME_FIT_CHANGE_DESIGN_CHANGED')
    diagnostics = {}
    comparisons = []
    unavailable = {'LEVEL': 0, 'CHANGE': 0}

    def match(role, old, new, oldvalue, newvalue, keyold, keynew, *, eligible=False):
        left = {keyold(r): r for r in old}
        right = {keynew(r): r for r in new}
        need(len(left) == len(old) and len(right) == len(new) and (set(left) == set(right)))
        ratios = []
        diffs = []
        dfs = []
        for key in sorted(left):
            a = left[key]
            b = right[key]
            av = _number(a[oldvalue])
            bv = _number(b[newvalue])
            need(math.isfinite(av) and math.isfinite(bv))
            need(math.isclose(av, bv, rel_tol=2e-07, abs_tol=1e-09), 'SAME_FIT_PREDICTION_CHANGED')
            diffs.append(abs(av - bv))
            if _uncertainty_unavailable(b, policy):
                need(eligible, 'SAME_FIT_UNAVAILABLE_NOT_PERMITTED')
                unavailable[role] += 1
                comparisons.append(dict(TargetRole=role, TargetKey=str(key), WorkingEstimate=av, WhiteEstimate=bv, WorkingSE=_number(a['stderr']), WhiteSE=None, WhiteDF=None, WhiteUncertainty=availability.UNAVAILABLE_REASON))
                continue
            se_a = _number(a['stderr'])
            se_b = _number(b['stderr'])
            if se_a > 0:
                ratios.append(se_b / se_a)
            if b['df'] not in ('', '.'):
                dfs.append(_number(b['df']))
            comparisons.append(dict(TargetRole=role, TargetKey=str(key), WorkingEstimate=av, WhiteEstimate=bv, WorkingSE=se_a, WhiteSE=se_b, WhiteDF=None if b['df'] in ('', '.') else _number(b['df'])))
        diagnostics[role] = dict(Count=len(left), MaximumAbsolutePointDifference=max(diffs, default=0), MinimumSERatio=min(ratios, default=None), MaximumSERatio=max(ratios, default=None), MinimumWhiteDF=min(dfs, default=None), MaximumWhiteDF=max(dfs, default=None))
    trajectory = w('trajectory')
    levels = c('levels')
    changes = c('changes')
    within = w('within_changes')
    cwithin = c('within')
    pair = w('pairwise')
    cpair = c('pairwise')
    keygrid = lambda r: int(_number(r['gridid']))
    match('LEVEL', trajectory, levels, 'predicted', 'estimate', keygrid, keygrid, eligible=True)
    match('WITHIN', within, cwithin, 'estimate', 'estimate', lambda r: int(_number(r['categorya'])), lambda r: int(_number(r['categoryindexa'])))
    match('PAIRWISE', pair, cpair, 'estimate', 'estimate', lambda r: (int(_number(r['categorya'])), int(_number(r['categoryb']))), lambda r: (int(_number(r['categoryindexa'])), int(_number(r['categoryindexb']))))
    ch = {keygrid(r): r for r in changes}
    need(set(ch) == set(range(1, n + 1)))
    traj = {keygrid(r): r for r in trajectory}
    need(len(traj) == len(trajectory) and set(traj) == set(range(1, n + 1)))
    for i, row in enumerate(delta):
        value = math.fsum((_number(a) * _number(b) for a, b in zip(row, beta)))
        need(math.isclose(value, _number(ch[i + 1]['estimate']), rel_tol=2e-07, abs_tol=1e-09), 'SAME_FIT_CHANGE_PREDICTION_CHANGED')
        if _uncertainty_unavailable(ch[i + 1], policy):
            unavailable['CHANGE'] += 1
            g = int(_number(grid[i]['gridid']))
            base = int(_number(grid[coordinate[int(_number(grid[i]['categoryindex'])), -60]]['gridid']))
            pt = _number(traj[g]['predicted'])
            pb = _number(traj[base]['predicted'])
            working_delta = _number(traj[g]['delta'])
            bound = max(2e-07 * abs(pt), 1e-09) + max(2e-07 * abs(pb), 1e-09)
            need(math.isfinite(working_delta) and abs(_number(ch[i + 1]['estimate']) - working_delta) <= bound, 'SAME_FIT_CHANGE_BASELINE_DIFFERENCE_CHANGED')
    need(all((state(path) == before for path, before in tracked.items())), 'COMPARISON_INPUT_CHANGED')
    result = dict(protocol=PROTOCOL, status='SAME_FIT_COMPARISON_PASSED', Scope='SAME_FIT_INFERENCE_ONLY', Context=expected, NumericExchange='EXACT_BINARY64' if exact_exchange else 'LEGACY_DECIMAL', Checks=dict(NativeCoefficientsExactlyPreserved=True, WorkingVariancesExactlyPreserved=True, ScoringDesignExactlyPreserved=True, ChangeDesignPreservedWithinSerializationBound=True, AllPredictionsReconstructed=True), Diagnostics=diagnostics, Comparisons=comparisons, OldFullResultsComparison=False, FullRunReady=False)
    if policy == availability.LCPU_V1:
        result['ScalarAvailabilityPolicy'] = policy
        result['UncertaintyUnavailableRows'] = dict(unavailable)
        result['Checks']['UnavailablePointsMatchWorkingEngine'] = True
    return result
