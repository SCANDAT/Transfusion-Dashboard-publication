"""Field and identity checks for bounds on archived variance calculations."""
from __future__ import annotations
import math, re
from fractions import Fraction
from roundoff_certificate_replay import METHOD, SCOPE, LIMIT, DF2_SIGNS
PROTOCOL = 'RBC_MOMENT_CERTIFICATE_ARCHIVE_V1'
VERSION = 1
ROLES = ('moment_error', 'scalar_weights', 'joint_weights', 'scalar_certificate', 'joint_certificate')
METRICS = ('Denominator', 'AbsError', 'RelativeErrorUpper', 'IdealRelativeErrorUpper', 'Resolved')
INTERVALS = ('NuLower', 'NuUpper', 'DF2Lower', 'DF2Upper', 'DF2Sign')
DESCRIPTOR_KEYS = {'CertificateProtocol', 'CertificateMethod', 'CertificateVersion', 'CertificateScope', 'RunId', 'FitId', 'Scope', 'ConstructionSourceSHA256', 'HostProbe', 'WeightProvenance', 'NumericTransport', 'SpanDimension', 'MomentDimension', 'TargetIndices', 'Tests'}
SCOPES = {'SYNTHETIC_DATA_ONLY', 'LOCAL_SAMPLE_MODEL_INFERENCE', 'FULL_COHORT_MODEL_INFERENCE'}
CERTIFICATE_CONTEXT_CHARS = ('CertificateProtocol', 'CertificateMethod', 'CertificateScope', 'ConstructionSourceSHA256', 'HostProbe', 'WeightProvenance', 'NumericTransport')
CERTIFICATE_CONTEXT_NUMS = ('CertificateVersion', 'SpanDimension', 'MomentDimension')
DECIMAL_METHOD = 'DECIMAL_DIRECTED_NATIVE_CENTER_V1'
DECIMAL_PRECISION = 80

class CertificateSchemaError(ValueError):
    pass

def need(condition, code):
    if not condition:
        raise CertificateSchemaError(code)

def integer(value, minimum=1):
    return type(value) is int and value >= minimum

def number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)

def missing(value):
    return value is None or (isinstance(value, float) and math.isnan(value))

def key(value):
    need(number(value) and value >= 1 and (value == int(value)), 'CERTIFICATE_KEY_INVALID')
    return int(value)

def validate_descriptor(value, *, expected=None):
    need(isinstance(value, dict) and set(value) == DESCRIPTOR_KEYS, 'CERTIFICATE_DESCRIPTOR_FIELDS')
    need(value['CertificateProtocol'] == PROTOCOL and value['CertificateMethod'] == METHOD and (type(value['CertificateVersion']) is int) and (value['CertificateVersion'] == VERSION) and (value['CertificateScope'] == SCOPE), 'CERTIFICATE_METHOD_INVALID')
    need(isinstance(value['RunId'], str) and len(value['RunId']) == 32 and isinstance(value['FitId'], str) and (0 < len(value['FitId']) <= 128) and (value['Scope'] in SCOPES), 'CERTIFICATE_CONTEXT_INVALID')
    need(isinstance(value['ConstructionSourceSHA256'], str) and re.fullmatch('[0-9a-f]{64}', value['ConstructionSourceSHA256']) and (value['HostProbe'] == 'PASS') and (value['WeightProvenance'] == 'NATIVE_BINARY64') and (value['NumericTransport'] == 'HEX16_IEEE754'), 'CERTIFICATE_PROVENANCE_INVALID')
    h = value['SpanDimension']
    d = value['MomentDimension']
    need(integer(h) and h <= 500 and integer(d) and (d == h * (h + 1) // 2) and (8 * d * d <= 512 * 2 ** 20), 'CERTIFICATE_DIMENSION_INVALID')
    targets = value['TargetIndices']
    tests = value['Tests']
    need(isinstance(targets, list) and 1 <= len(targets) <= 200000 and all((integer(i) for i in targets)) and (targets == sorted(set(targets))), 'CERTIFICATE_TARGET_PLAN_INVALID')
    need(isinstance(tests, list) and len(tests) <= 200000, 'CERTIFICATE_JOINT_PLAN_INVALID')
    seen = []
    for test in tests:
        need(isinstance(test, dict) and set(test) == {'TestIndex', 'ConstraintIndices'} and integer(test['TestIndex']) and isinstance(test['ConstraintIndices'], list), 'CERTIFICATE_JOINT_PLAN_INVALID')
        constraints = test['ConstraintIndices']
        need(1 <= len(constraints) <= h and all((integer(i) for i in constraints)) and (constraints == list(range(1, len(constraints) + 1))), 'CERTIFICATE_JOINT_PLAN_INVALID')
        seen.append(test['TestIndex'])
    need(seen == sorted(set(seen)), 'CERTIFICATE_JOINT_PLAN_INVALID')
    if expected is not None:
        need(isinstance(expected, dict) and set(expected) <= DESCRIPTOR_KEYS and all((value[k] == v for k, v in expected.items())), 'CERTIFICATE_EXPECTED_BINDING_MISMATCH')
    return value

def descriptor(*, run_id, fit_id, scope, construction_source_sha256, span_dimension, target_indices, tests):
    return validate_descriptor(dict(CertificateProtocol=PROTOCOL, CertificateMethod=METHOD, CertificateVersion=VERSION, CertificateScope=SCOPE, RunId=run_id, FitId=fit_id, Scope=scope, ConstructionSourceSHA256=construction_source_sha256, HostProbe='PASS', WeightProvenance='NATIVE_BINARY64', NumericTransport='HEX16_IEEE754', SpanDimension=span_dimension, MomentDimension=span_dimension * (span_dimension + 1) // 2, TargetIndices=list(target_indices), Tests=list(tests)))

def descriptor_from_context(context, *, target_indices, tests, expected=None):
    """Convert one already identity-checked native context row plus frozen keys."""
    fields = set(CERTIFICATE_CONTEXT_CHARS + CERTIFICATE_CONTEXT_NUMS) | {'RunId', 'FitId', 'Scope'}
    need(isinstance(context, dict) and set(context) == fields, 'CERTIFICATE_CONTEXT_FIELDS')
    value = dict(context)
    for name in CERTIFICATE_CONTEXT_NUMS:
        value[name] = key(value[name])
    value['TargetIndices'] = list(target_indices)
    value['Tests'] = list(tests)
    return validate_descriptor(value, expected=expected)

def schemas(value):
    """Existing intake-compatible (character fields, numeric fields, exact rows)."""
    validate_descriptor(value)
    h = value['SpanDimension']
    d = value['MomentDimension']
    cols = lambda n: tuple(('COL' + str(i) for i in range(1, n + 1)))
    targets = len(value['TargetIndices'])
    tests = len(value['Tests'])
    constraints = sum((len(test['ConstraintIndices']) for test in value['Tests']))
    return {'moment_error': ((), cols(d), d), 'scalar_weights': ((), ('TargetIndex',) + cols(h), targets), 'joint_weights': ((), ('TestIndex', 'ConstraintIndex') + cols(h), constraints), 'scalar_certificate': ((), ('TargetIndex',) + METRICS, targets), 'joint_certificate': ((), ('TestIndex',) + METRICS + INTERVALS, tests)}

def _fraction(value):
    return Fraction(float(value))

def _metric(row, *, zero=False):
    need(number(row['Resolved']) and row['Resolved'] in (0, 1), 'CERTIFICATE_RESOLVED_INVALID')
    fields = METRICS[:-1]
    if zero:
        need(row['Resolved'] == 0 and all((missing(row[name]) for name in fields)), 'CERTIFICATE_ZERO_TARGET_INVALID')
        return
    d, e = (row['Denominator'], row['AbsError'])
    r = row['RelativeErrorUpper']
    ideal = row['IdealRelativeErrorUpper']
    need(number(d) and number(e) and (e >= 0), 'CERTIFICATE_BOUND_INVALID')
    if d <= 0:
        need(missing(r) and missing(ideal) and (row['Resolved'] == 0), 'CERTIFICATE_RATIO_INVALID')
        return
    need(number(r) and r >= 0 and (_fraction(r) >= _fraction(e) / _fraction(d)), 'CERTIFICATE_RATIO_UNDERBOUND')
    if r >= 0.25:
        need(missing(ideal) and row['Resolved'] == 0, 'CERTIFICATE_RATIO_INVALID')
        return
    need(number(ideal) and ideal >= 0 and (_fraction(ideal) >= _fraction(r) / (1 - _fraction(r))), 'CERTIFICATE_IDEAL_RATIO_UNDERBOUND')
    need(bool(row['Resolved']) == (ideal <= LIMIT), 'CERTIFICATE_RESOLVED_POLICY_MISMATCH')

def _joint_interval(row, q):
    fields = INTERVALS[:-1]
    sign = row['DF2Sign']
    need(number(sign) and sign in set(DF2_SIGNS.values()), 'CERTIFICATE_DF_SIGN_INVALID')
    d, e = (row['Denominator'], row['AbsError'])
    if sign == DF2_SIGNS['UNAVAILABLE'] and row['Resolved'] == 0:
        need(all((missing(row[k]) for k in fields)), 'CERTIFICATE_DF_INTERVAL_INVALID')
        return
    if not (number(d) and number(e)) or d <= e or d <= 0:
        need(sign == DF2_SIGNS['UNAVAILABLE'] and all((missing(row[k]) for k in fields)), 'CERTIFICATE_DF_INTERVAL_UNAVAILABLE_REQUIRED')
        return
    need(all((number(row[k]) for k in fields)), 'CERTIFICATE_DF_INTERVAL_INVALID')
    nl, nu, dl, du = (row[k] for k in fields)
    need(0 < nl <= nu and dl <= du, 'CERTIFICATE_DF_INTERVAL_INVALID')
    true_nl = Fraction(q * (q + 1)) / (_fraction(d) + _fraction(e))
    true_nu = Fraction(q * (q + 1)) / (_fraction(d) - _fraction(e))
    need(_fraction(nl) <= true_nl and _fraction(nu) >= true_nu and (_fraction(dl) <= _fraction(nl) - (q - 1)) and (_fraction(du) >= _fraction(nu) - (q - 1)), 'CERTIFICATE_DF_INTERVAL_UNDERBOUND')
    expected = DF2_SIGNS['POSITIVE'] if dl > 0 else DF2_SIGNS['NONPOSITIVE'] if du <= 0 else DF2_SIGNS['UNRESOLVED']
    need(sign == expected, 'CERTIFICATE_DF_SIGN_INVALID')

def validate_tables(value, tables):
    """Validate exact role payloads against frozen keys; never infer provenance.

    Independent contraction replay must additionally receive the archived moment
    M, these exact-native weights and archived denominator. This function alone
    never certifies a model/result or asserts FullRunReady.
    """
    spec = schemas(value)
    need(isinstance(tables, dict) and set(tables) == set(ROLES), 'CERTIFICATE_ROLES_INVALID')
    for role, (_, columns, count) in spec.items():
        rows = tables[role]
        need(isinstance(rows, list) and len(rows) == count, 'CERTIFICATE_ROW_COUNT_INVALID')
        for row in rows:
            need(isinstance(row, dict) and set(row) == set(columns), 'CERTIFICATE_ROW_FIELDS_INVALID')
    for row in tables['moment_error']:
        need(all((number(v) and v >= 0 for v in row.values())), 'CERTIFICATE_MOMENT_ERROR_INVALID')
    h = value['SpanDimension']
    columns = tuple(('COL' + str(i) for i in range(1, h + 1)))
    scalar = {}
    for row in tables['scalar_weights']:
        index = key(row['TargetIndex'])
        need(index not in scalar and all((number(row[c]) for c in columns)), 'CERTIFICATE_NATIVE_WEIGHTS_INVALID')
        scalar[index] = [row[c] for c in columns]
    need(set(scalar) == set(value['TargetIndices']), 'CERTIFICATE_TARGET_KEY_MISMATCH')
    joint = {}
    for row in tables['joint_weights']:
        pair = (key(row['TestIndex']), key(row['ConstraintIndex']))
        need(pair not in joint and all((number(row[c]) for c in columns)), 'CERTIFICATE_NATIVE_WEIGHTS_INVALID')
        joint[pair] = [row[c] for c in columns]
    expected = {(test['TestIndex'], i) for test in value['Tests'] for i in test['ConstraintIndices']}
    need(set(joint) == expected, 'CERTIFICATE_JOINT_KEY_MISMATCH')
    seen = set()
    for row in tables['scalar_certificate']:
        index = key(row['TargetIndex'])
        need(index in scalar and index not in seen, 'CERTIFICATE_TARGET_KEY_MISMATCH')
        seen.add(index)
        _metric(row, zero=all((w == 0 for w in scalar[index])))
    need(seen == set(scalar), 'CERTIFICATE_TARGET_KEY_MISMATCH')
    ranks = {test['TestIndex']: len(test['ConstraintIndices']) for test in value['Tests']}
    seen = set()
    for row in tables['joint_certificate']:
        index = key(row['TestIndex'])
        need(index in ranks and index not in seen, 'CERTIFICATE_JOINT_KEY_MISMATCH')
        seen.add(index)
        _metric(row)
        _joint_interval(row, ranks[index])
    need(seen == set(ranks), 'CERTIFICATE_JOINT_KEY_MISMATCH')
    return dict(Status='CERTIFICATE_SCHEMA_VALIDATED', Method=METHOD, NativeScoringWeightsRequired=True, ConstructionProofReplayed=False, FullRunReady=False)

def _scalar_gates(row, out):
    """Unchanged acceptance: native radius dominates, native resolution replayed."""
    need(row['AbsError'] >= out['absolute_error'], 'CERTIFICATE_NATIVE_RADIUS_BELOW_REPLAY')
    need(row['Resolved'] != 1 or out['resolved'], 'CERTIFICATE_NATIVE_RESOLUTION_NOT_REPLAYED')

def _tight_replay(M, E, inconclusive, scalar, decimal_replay):
    """Directed Decimal replay at the SAME native centers for inconclusive targets only.

    decimal_replay None: historical in-process serial engine (unchanged arithmetic).
    Otherwise a DecimalReplayRunner executes the identical arithmetic (serial or
    pooled per its recorded policy); any operational failure raises
    DecimalReplayUnavailable, which is NOT a scientific rejection and is never
    converted into one here.

    Integration boundary: every returned dictionary, from either path, must pass
    decimal_replay_policy.verify_results before it is consumed: exact keys and
    types, decimal_precision exactly 80, the Decimal engine's identity fields,
    denominator bit-identical to the native center handed in (signed zero
    included), finite nonnegative absolute_error, and ratio/resolved fields
    bit-identical to the authoritative _finish recomputation (unchanged 2e-8
    rule; positive infinity exactly where _finish produces it: both ratios for
    a nonpositive center, the ideal ratio when the computed ratio is >= 0.25,
    both legitimately unresolved and accepted as such). A malformed or
    inconsistent reply raises DecimalReplayUnavailable (operational UNCERTIFIED):
    it is neither accepted nor turned into a scientific rejection. Valid
    dictionaries are returned unaltered. Returns {target index: result} complete.
    """
    targets = [(index, scalar[index], row['Denominator']) for index, row in inconclusive]
    from decimal_verification import DecimalReplayUnavailable, verify_results
    if decimal_replay is None:
        from decimal_scalar_replay import DecimalScalarReplay
        try:
            engine = DecimalScalarReplay(M, E, precision=DECIMAL_PRECISION)
            results = {index: engine.replay(w, c) for index, w, c in targets}
        except (ValueError, ArithmeticError, FloatingPointError):
            raise CertificateSchemaError('CERTIFICATE_REPLAY_FAILED') from None
    else:
        try:
            results = decimal_replay.replay(M, E, targets)
        except DecimalReplayUnavailable:
            raise
        except (ValueError, ArithmeticError, FloatingPointError):
            raise CertificateSchemaError('CERTIFICATE_REPLAY_FAILED') from None
    return verify_results(results, {index: center for index, _, center in targets})

def validate_contractions(value, tables, moment, *, expected, decimal_replay=None):
    """Independent, fail-closed replay at exact native weights/native centers.

    The reported native radius must dominate this independent recentered radius;
    failure is a validation rejection, never an automatic tolerance increase.
    A conservative native unresolved status is retained even if replay resolves.
    An inconclusive fast scalar radius uses directed Decimal replay at the SAME
    native center; the native radius and 2e-8 acceptance rule remain unchanged.
    Trusted expected identities, closure hash and frozen keys are mandatory.
    decimal_replay: optional DecimalReplayRunner; only targets the unchanged fast
    replay left inconclusive are ever handed to it. Fast-resolved targets are
    never replaced. Every Decimal dictionary (either path) is verified at the
    integration boundary (_tight_replay) before the scientific gates see it; a
    malformed or inconsistent dictionary is DecimalReplayUnavailable, never a
    CertificateSchemaError and never an accepted result.
    """
    import numpy as np
    import time
    from roundoff_certificate_replay import scalar_denominators, joint_denominator
    required = {'RunId', 'FitId', 'Scope', 'ConstructionSourceSHA256', 'SpanDimension', 'MomentDimension', 'TargetIndices', 'Tests'}
    need(isinstance(expected, dict) and required <= set(expected), 'CERTIFICATE_TRUSTED_EXPECTED_REQUIRED')
    validate_descriptor(value, expected=expected)
    validate_tables(value, tables)
    M = np.asarray(moment, dtype=float)
    d = value['MomentDimension']
    h = value['SpanDimension']
    need(M.shape == (d, d) and np.isfinite(M).all(), 'CERTIFICATE_MOMENT_INVALID')
    E = np.asarray([[row['COL' + str(i + 1)] for i in range(d)] for row in tables['moment_error']], dtype=float)
    scalar = {key(row['TargetIndex']): np.array([row['COL' + str(i + 1)] for i in range(h)], dtype=float) for row in tables['scalar_weights']}
    joint = {(key(row['TestIndex']), key(row['ConstraintIndex'])): np.array([row['COL' + str(i + 1)] for i in range(h)], dtype=float) for row in tables['joint_weights']}
    checked_scalar = checked_joint = zero = 0
    scalar_fallbacks = 0
    scalar_fallback_seconds = 0.0
    mode = 'NOT_REQUIRED'
    native_unresolved = []
    unresolved_decimal = []
    unresolved_replay_resolves = []
    rows = [row for row in tables['scalar_certificate'] if not np.all(scalar[key(row['TargetIndex'])] == 0)]
    zero = len(tables['scalar_certificate']) - len(rows)
    if rows:
        weights = np.vstack([scalar[key(row['TargetIndex'])] for row in rows])
        centers = np.asarray([row['Denominator'] for row in rows], dtype=float)
        try:
            outputs = scalar_denominators(M, E, weights, archived_denominators=centers)
        except (ValueError, ArithmeticError, FloatingPointError):
            raise CertificateSchemaError('CERTIFICATE_REPLAY_FAILED') from None
        inconclusive = []
        for row, out in zip(rows, outputs):
            if row['AbsError'] < out['absolute_error'] or (row['Resolved'] == 1 and (not out['resolved'])):
                inconclusive.append((key(row['TargetIndex']), row))
            else:
                _scalar_gates(row, out)
                checked_scalar += 1
                if row['Resolved'] != 1:
                    native_unresolved.append(key(row['TargetIndex']))
                    if out['resolved']:
                        unresolved_replay_resolves.append(key(row['TargetIndex']))
        if inconclusive:
            began = time.monotonic()
            tight = _tight_replay(M, E, inconclusive, scalar, decimal_replay)
            scalar_fallback_seconds = time.monotonic() - began
            scalar_fallbacks = len(inconclusive)
            mode = 'IN_PROCESS_SERIAL' if decimal_replay is None else str((decimal_replay.receipt() or {}).get('Mode'))
            for index, row in inconclusive:
                _scalar_gates(row, tight[index])
                checked_scalar += 1
                if row['Resolved'] != 1:
                    native_unresolved.append(index)
                    unresolved_decimal.append(index)
                    if tight[index]['resolved']:
                        unresolved_replay_resolves.append(index)
    ranks = {test['TestIndex']: len(test['ConstraintIndices']) for test in value['Tests']}
    for row in tables['joint_certificate']:
        index = key(row['TestIndex'])
        weights = np.vstack([joint[index, i] for i in range(1, ranks[index] + 1)])
        try:
            out = joint_denominator(M, E, weights, archived_denominator=row['Denominator'])
        except (ValueError, ArithmeticError, FloatingPointError):
            raise CertificateSchemaError('CERTIFICATE_REPLAY_FAILED') from None
        need(row['AbsError'] >= out['absolute_error'], 'CERTIFICATE_NATIVE_RADIUS_BELOW_REPLAY')
        need(row['Resolved'] != 1 or out['resolved'], 'CERTIFICATE_NATIVE_RESOLUTION_NOT_REPLAYED')
        if row['Resolved'] == 1 and row['DF2Sign'] == DF2_SIGNS['POSITIVE']:
            need(out['inference_supported'], 'CERTIFICATE_POSITIVE_DF_NOT_REPLAYED')
        checked_joint += 1
    return dict(Status='CERTIFICATE_CONTRACTIONS_VALIDATED', ScalarContractions=checked_scalar, ZeroScalarTargets=zero, JointContractions=checked_joint, ConstructionProofReplayed=False, NativeCentersPreserved=True, NativeWeightsReconstructed=False, ScalarFallbackContractions=scalar_fallbacks, ScalarFallbackSeconds=scalar_fallback_seconds, ScalarFallbackMethod=DECIMAL_METHOD if scalar_fallbacks else 'NOT_REQUIRED', ScalarFallbackPrecision=DECIMAL_PRECISION if scalar_fallbacks else None, ScalarFallbackMode=mode, NativeUnresolvedScalarTargets=sorted(native_unresolved), NativeUnresolvedDecimalVerified=sorted(unresolved_decimal), NativeUnresolvedReplayResolves=sorted(unresolved_replay_resolves), FullRunReady=False)
