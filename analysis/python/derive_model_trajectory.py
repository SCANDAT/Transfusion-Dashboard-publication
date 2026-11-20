"""Reconstruct fitted trajectories and changes from the reference measurement."""
from __future__ import annotations
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import numpy as np
from validate_model_archive import validate, CONTEXT, ROLES
from validate_model_exchange import validate_exchange, table, require, number, integer, unique, ExchangeError
from file_utils import regular_file, private_directory
PROTOCOL = 'RBC_TRAJECTORY_CHANGES_V1'
STATUS = 'DERIVED_AND_VALIDATED'
COVARIANCE_SOURCE = 'VALIDATED_JOINT_ANCHOR_COVARIANCE'
CI_ADJUSTMENT = 'None: pointwise'
DERIVATION_ALGORITHM = 'EXACT_A_POSTERIORI_CONTRAST_CERTIFICATE_V3'
NUMERIC = tuple('GridID CategoryIndex CategoryCode TimeFromTransfusion BaselineMinute Delta DeltaStdErr DeltaLower DeltaUpper DeltaDF Alpha'.split())
FIELDS = (*CONTEXT, *NUMERIC, 'CIAdjustment', 'CovarianceSource')

def _bytes(path: Path, limit=64 * 1024 * 1024):
    require(regular_file(path, limit))
    a = path.stat()
    before = (a.st_size, a.st_mtime_ns, a.st_dev, a.st_ino)
    payload = path.read_bytes()
    a = path.stat()
    after = (a.st_size, a.st_mtime_ns, a.st_dev, a.st_ino)
    require(before == after and len(payload) == before[0])
    return payload

def _input_digest(folder, job):
    hashes = {role: hashlib.sha256(_bytes(folder / (job + '_' + role + '.csv'))).hexdigest() for role in (*ROLES, 'archive_manifest')}
    return hashlib.sha256(json.dumps(hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def _close(actual, expected, *, atol=0.0, rtol=1e-07):
    require(bool(np.isclose(actual, expected, rtol=rtol, atol=atol)))

def _gamma(n):
    unit = np.finfo(float).eps / 2
    require(n * unit < 1)
    return n * unit / (1 - n * unit)

def _two_difference(left, right):
    """Error-free difference of finite parsed doubles (gradual underflow).

    Unlike u*(|left|+|right|), this retains exact cancellation of identical
    nuisance columns and Sterbenz-exact differences of nearby design entries.
    """
    difference = left - right
    virtual_right = left - difference
    virtual_left = difference + virtual_right
    residual = left - virtual_left + (virtual_right - right)
    require(bool(np.isfinite(difference).all() and np.isfinite(residual).all()))
    return (difference, residual)

def _compensated_product(matrix, vector):
    """Compensated accumulation; product rounding still has an explicit bound."""
    result = np.array([math.fsum((float(a) * float(b) for a, b in zip(row, vector))) for row in matrix])
    magnitude = np.abs(matrix) @ np.abs(vector)
    bound = _gamma(2 * matrix.shape[1] + 4) * magnitude
    bound += matrix.shape[1] * np.nextafter(0.0, 1.0)
    require(bool(np.isfinite(result).all() and np.isfinite(bound).all()))
    return (result, np.nextafter(bound, np.inf))

def _mean_changes(score, anchor, beta, means, anchor_means, weights, baseline):
    """Stable means with componentwise parsed-array consistency certificates.

    Existing model/source tolerances remain independent requirements. Their
    residuals are NOT called machine roundoff: E32 serialization is approximate.
    Bounds below certify arithmetic consistency of the parsed archived numbers,
    not unknowable exact pre-serialization SAS doubles or scientific approval.
    """
    require(score.ndim == 2 and anchor.ndim == 2 and (score.shape[1] == anchor.shape[1] == len(beta)))
    require(weights.shape == (len(score), len(anchor)) and means.shape == (len(score),) and (anchor_means.shape == (len(anchor),)))
    require(all((np.isfinite(x).all() for x in (score, anchor, beta, means, anchor_means, weights))))
    source_scale = max(float(np.max(np.abs(means))), float(np.max(np.abs(anchor_means))), 1e-100)
    fitted, fitted_error = _compensated_product(score, beta)
    fitted_anchor, anchor_error = _compensated_product(anchor, beta)
    require(bool(np.allclose(fitted, means, rtol=1e-07, atol=1e-12 * source_scale)))
    require(bool(np.allclose(fitted_anchor, anchor_means, rtol=1e-07, atol=1e-12 * source_scale)))
    design_difference, design_difference_error = _two_difference(score, score[baseline])
    delta, delta_dot_error = _compensated_product(design_difference, beta)
    delta_arithmetic_error = delta_dot_error + np.abs(design_difference_error) @ np.abs(beta)
    delta_arithmetic_error = np.nextafter(delta_arithmetic_error * (1 + _gamma(2 * score.shape[1] + 4)) + (score.shape[1] + 1) * np.nextafter(0.0, 1.0), np.inf)
    tolerance = 1e-07 * np.abs(delta) + 1e-12 * source_scale
    unresolved = np.flatnonzero(delta_arithmetic_error > tolerance)
    if len(unresolved):
        from exact_arithmetic_certificate import certify_existing_difference, CertificateError
        for index in unresolved:
            try:
                certified = certify_existing_difference(score[index], score[baseline[index]], beta, delta[index], tolerance[index])
            except CertificateError:
                require(False)
            delta_arithmetic_error[index] = certified
    require(bool(np.all(delta_arithmetic_error <= tolerance)))
    anchor_difference, _ = _two_difference(weights, weights[baseline])
    from_anchors, anchor_dot_error = _compensated_product(anchor_difference, anchor_means)
    span = anchor_difference @ anchor
    span_difference, span_subtraction_error = _two_difference(span, design_difference)
    span_magnitude = np.abs(anchor_difference) @ np.abs(anchor)
    span_product_error = np.nextafter((_gamma(len(anchor)) * span_magnitude + len(anchor) * np.nextafter(0.0, 1.0)) * (1 + _gamma(2 * len(anchor) + 4)), np.inf)
    span_bound = np.abs(span_difference) + span_product_error + np.abs(span_subtraction_error)
    column_scale = np.maximum(np.max(np.abs(anchor), axis=0), np.max(np.abs(score), axis=0))
    column_scale[column_scale == 0] = 1.0
    span_numerical = (span_product_error + np.abs(span_subtraction_error)) / column_scale
    require(bool(np.all(np.abs(span_difference) / column_scale <= 2e-10 + span_numerical)))
    residual_anchor, residual_anchor_error = _two_difference(anchor_means, fitted_anchor)
    anchor_residual_bound = np.abs(residual_anchor) + anchor_error + np.abs(residual_anchor_error)
    bound = np.abs(anchor_difference) @ anchor_residual_bound + span_bound @ np.abs(beta) + anchor_dot_error + delta_dot_error
    bound *= 1 + _gamma(2 * score.shape[1] + 2 * len(anchor) + 8)
    discrepancy, discrepancy_error = _two_difference(from_anchors, delta)
    require(bool(np.isfinite(bound).all() and np.all(np.abs(discrepancy) <= np.nextafter(bound + np.abs(discrepancy_error), np.inf))))
    source_delta, source_delta_error = _two_difference(means, means[baseline])
    residual_score, residual_score_error = _two_difference(means, fitted)
    level_bound = np.abs(residual_score) + fitted_error + np.abs(residual_score_error)
    source_bound = level_bound + level_bound[baseline] + delta_arithmetic_error + np.abs(source_delta_error)
    discrepancy, discrepancy_error = _two_difference(source_delta, delta)
    require(bool(np.isfinite(source_bound).all() and np.all(np.abs(discrepancy) <= np.nextafter(source_bound * (1 + _gamma(8)) + np.abs(discrepancy_error), np.inf))))
    return (delta, anchor_difference)

def _prepare(folder, job, expected):
    certified = validate(folder, job, expected)
    require(certified['status'] == 'VALIDATED')
    identity, _ = table(folder, job, 'identity', CONTEXT)
    identity = identity[0]
    require(identity['InferenceStatus'] == 'MODEL_BASED_CANDIDATE' and identity['DFMethod'] == 'RESIDUAL')
    meta, _ = table(folder, job, 'fitmetadata', ('N_Categories', 'ResidualDF', 'N_DesignColumns'))
    meta = meta[0]
    k = integer(meta, 'N_Categories')
    df = number(meta, 'ResidualDF')
    ref, _ = table(folder, job, 'inference_reference', ('Alpha', 'DF', 'CriticalValue'))
    ref = ref[0]
    alpha = number(ref, 'Alpha')
    critical = number(ref, 'CriticalValue')
    require(alpha == 0.05 and number(ref, 'DF') == df and (df > 0) and (critical > 0))
    archive = validate_exchange(folder, job, k)
    raw, _ = table(folder, job, 'trajectory', ('GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', 'Predicted'))
    curve = unique(raw, 'GridID')
    ids = sorted(curve)
    require(len(ids) == len(archive.grid_weights))
    coordinates = {(integer(curve[g], 'CategoryIndex'), integer(curve[g], 'TimeFromTransfusion')): i for i, g in enumerate(ids)}
    require(len(coordinates) == len(ids))
    baseline = np.array([coordinates[integer(curve[g], 'CategoryIndex'), -60] for g in ids])
    means = np.array([number(curve[g], 'Predicted') for g in ids])
    p = integer(meta, 'N_DesignColumns')
    columns = ['RBCX' + str(i) for i in range(1, p + 1)]
    score_rows, _ = table(folder, job, 'score_design', ('GridID', *columns))
    score_map = unique(score_rows, 'GridID')
    anchor_rows, _ = table(folder, job, 'anchor_design', ('AnchorID', *columns))
    anchor_map = unique(anchor_rows, 'AnchorID')
    solution, _ = table(folder, job, 'solution', ('Effect', 'Estimate'))
    coefficients = {row['Effect'].upper(): number(row, 'Estimate') for row in solution}
    require(set(score_map) == set(ids) and set(anchor_map) == set(range(1, 9 * k + 1)) and (set(coefficients) == set(columns)))
    score = np.array([[number(score_map[g], c) for c in columns] for g in ids])
    anchor = np.array([[number(anchor_map[a], c) for c in columns] for a in sorted(anchor_map)])
    beta = np.array([coefficients[c] for c in columns])
    delta, weights = _mean_changes(score, anchor, beta, means, archive.anchor_mean, archive.grid_weights, baseline)
    scale = max(float(np.max(np.abs(means))), float(np.max(np.abs(archive.anchor_mean))), 1e-100)
    cov = archive.anchor_covariance
    variance = np.einsum('ij,jk,ik->i', weights, cov, weights)
    bounds = 64 * np.finfo(float).eps * np.einsum('ij,jk,ik->i', np.abs(weights), np.abs(cov), np.abs(weights))
    require(bool(np.isfinite(variance).all() and np.all(variance >= -bounds)))
    se = np.sqrt(np.maximum(0.0, variance))
    lower = delta - critical * se
    upper = delta + critical * se
    rows = []
    for i, gid in enumerate(ids):
        r = curve[gid]
        category = integer(r, 'CategoryIndex')
        time = integer(r, 'TimeFromTransfusion')
        if time == -60:
            require(bool(np.all(weights[i] == 0)))
            delta[i] = se[i] = lower[i] = upper[i] = 0.0
        rows.append(dict(identity, GridID=gid, CategoryIndex=category, CategoryCode=number(r, 'CategoryCode'), TimeFromTransfusion=time, BaselineMinute=-60, Delta=float(delta[i]), DeltaStdErr=float(se[i]), DeltaLower=float(lower[i]), DeltaUpper=float(upper[i]), DeltaDF=df, Alpha=alpha, CIAdjustment=CI_ADJUSTMENT, CovarianceSource=COVARIANCE_SOURCE))
    within, _ = table(folder, job, 'within_changes', ('CategoryA', 'CategoryCodeA', 'Estimate', 'StdErr', 'DF', 'Lower', 'Upper'))
    require(len(within) == k)
    seen = set()
    for r in within:
        cat = integer(r, 'CategoryA')
        require(cat not in seen)
        seen.add(cat)
        got = rows[coordinates[cat, 60]]
        require(got['CategoryCode'] == number(r, 'CategoryCodeA') and got['DeltaDF'] == number(r, 'DF'))
        _close(got['Delta'], number(r, 'Estimate'), atol=1e-12 * scale)
        _close(got['DeltaStdErr'], number(r, 'StdErr'), atol=1e-12 * max(got['DeltaStdErr'], abs(number(r, 'StdErr'))))
        ci_scale = max(abs(got['Delta']), critical * got['DeltaStdErr'], 1e-100)
        _close(got['DeltaLower'], number(r, 'Lower'), atol=1e-12 * ci_scale)
        _close(got['DeltaUpper'], number(r, 'Upper'), atol=1e-12 * ci_scale)
    require(seen == set(range(1, k + 1)))
    require(_input_digest(folder, job) == certified['ArchiveContentDigest'])
    return (rows, identity, certified['ArchiveContentDigest'])

def _locations(folder, job, output_dir):
    folder = Path(folder)
    out = folder if output_dir is None else Path(output_dir)
    require(private_directory(out))
    return (folder, out / (job + '_trajectory_changes.csv'), out / (job + '_trajectory_changes_status.json'))

def _csv(rows):
    stream = io.StringIO(newline='')
    writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator='\n')
    writer.writeheader()
    for row in rows:
        result = dict(row)
        for key in NUMERIC:
            require(np.isfinite(result[key]))
            result[key] = format(result[key], '.17g')
        writer.writerow(result)
    return stream.getvalue().encode('utf-8')

def _report(identity, input_digest, payload, filename):
    return dict(protocol=PROTOCOL, status=STATUS, Context=identity, ArchiveContentDigest=input_digest, TrajectoryChangesDigest=hashlib.sha256(payload).hexdigest(), FileName=filename, CovarianceSource=COVARIANCE_SOURCE, DerivationAlgorithm=DERIVATION_ALGORITHM, ArithmeticValidationScope='PARSED_ARCHIVE_FORWARD_ERROR_BOUNDS', SourceNumericAccuracy='INHERITED_MODEL_ARCHIVE_CHECKS_NOT_EXACT_SAS_BITS', ValidationScope='ALL_MINUTE_BASELINE_CHANGES_DIRECT_ENDPOINT_SE_CI', ScientificApproval='NOT_GRANTED', FullRunReady=False)

def _result(report, sidecar):
    return {k: report[k] for k in ('protocol', 'status', 'ArchiveContentDigest', 'TrajectoryChangesDigest', 'ScientificApproval', 'FullRunReady')} | {'DerivedStatusDigest': hashlib.sha256(sidecar).hexdigest()}

def derive(folder, job, expected, *, output_dir=None):
    """Require a validated input archive and two fresh targets; never overwrite."""
    try:
        rows, identity, input_digest = _prepare(Path(folder), job, expected)
        folder, target, statusfile = _locations(folder, job, output_dir)
        require(not target.exists() and (not target.is_symlink()) and (not statusfile.exists()) and (not statusfile.is_symlink()))
        payload = _csv(rows)
        report = _report(identity, input_digest, payload, target.name)
        sidecar = (json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
        with target.open('xb') as stream:
            require(stream.write(payload) == len(payload))
        require(hashlib.sha256(_bytes(target)).hexdigest() == report['TrajectoryChangesDigest'])
        require(_input_digest(folder, job) == input_digest)
        with statusfile.open('xb') as stream:
            require(stream.write(sidecar) == len(sidecar))
        require(_bytes(statusfile, 65536) == sidecar)
        return _result(report, sidecar)
    except Exception:
        raise ExchangeError('MODEL_TRAJECTORY_DERIVATION_FAILED') from None

def verify_derived(folder, job, expected, *, output_dir=None):
    """Read-only resume validation: immutable digests plus all derived mathematics."""
    try:
        rows, identity, input_digest = _prepare(Path(folder), job, expected)
        folder, target, statusfile = _locations(folder, job, output_dir)
        payload = _bytes(target)
        sidecar = _bytes(statusfile, 65536)
        report = json.loads(sidecar.decode('utf-8'))
        require(report == _report(identity, input_digest, payload, target.name))
        reader = csv.DictReader(io.StringIO(payload.decode('utf-8'), newline=''))
        require(tuple(reader.fieldnames or ()) == FIELDS)
        saved = list(reader)
        require(len(saved) == len(rows))
        for actual, reference in zip(saved, rows):
            require(None not in actual and None not in actual.values())
            require(all((actual[key] == reference[key] for key in CONTEXT)))
            require(actual['CIAdjustment'] == CI_ADJUSTMENT and actual['CovarianceSource'] == COVARIANCE_SOURCE)
            for key in NUMERIC:
                got = number(actual, key)
                value = reference[key]
                if key in {'GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', 'BaselineMinute', 'DeltaDF', 'Alpha'} or reference['TimeFromTransfusion'] == -60:
                    require(got == value)
                else:
                    _close(got, value, rtol=1e-07, atol=1e-12 * max(abs(value), 1e-100))
        require(_input_digest(folder, job) == input_digest)
        require(_bytes(target) == payload and _bytes(statusfile, 65536) == sidecar)
        return _result(report, sidecar)
    except Exception:
        raise ExchangeError('MODEL_TRAJECTORY_DERIVATION_FAILED') from None
