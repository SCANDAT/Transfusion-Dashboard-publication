"""Use recorded error bounds to check scalar and joint degrees of freedom."""
import numpy as np
from moment_error_certificate import Ball, finite, pairs, scale, sym_square, dot_up, dot_round, add_up, up
from recenter_certificate import recenter
LIMIT = 2e-08
METHOD = 'ENTRYWISE_COMPUTED_GEOMETRY_V1'
SCOPE = 'COMPUTED_H_L_AND_NATIVE_SCORING_WEIGHT_CONTRACTION_ONLY'
DF2_SIGNS = {'POSITIVE': 1, 'NONPOSITIVE': -1, 'UNRESOLVED': 0, 'UNAVAILABLE': 2}

def _moment(M, E, h):
    M, E = (finite(M), finite(E))
    d = h * (h + 1) // 2
    if M.shape != (d, d) or E.shape != (d, d) or np.any(E < 0):
        raise ValueError('MOMENT_CERTIFICATE_DIMENSION_OR_SIGN')
    return Ball(M, E)

def _archived_center(ball, value):
    if value is None:
        return ball
    if isinstance(value, (bool, np.bool_)):
        raise ValueError('ARCHIVED_DENOMINATOR_INVALID')
    native = finite(value)
    if native.ndim != 0:
        raise ValueError('ARCHIVED_DENOMINATOR_INVALID')
    return recenter(native.reshape(ball.value.shape), ball)

def _finish(ball, *, archived=False):
    value = float(ball.value.item())
    error = float(ball.error.item())
    relative = ideal_relative = float('inf')
    if value > 0:
        relative = float(up(error / value))
        if relative < 0.25:
            divisor = 1 - 2 * max(relative, 2.0 ** (-52))
            ideal_relative = float(up(relative / divisor))
    return dict(method=METHOD, denominator=value, absolute_error=error, relative_to_computed=relative, relative_to_positive_ideal=ideal_relative, resolved=bool(value > 0 and ideal_relative <= LIMIT), scope=SCOPE, archived_center_supplied=archived)

def joint_df_interval(denominator, absolute_error, q):
    """Outward nu and df2 intervals, conditional on the SAME computed native Wn.

    This certifies the sign only when the entire interval has that sign. It
    does not certify the Wald statistic, p value, all geometry errors, or a
    chosen low-df warning threshold. Unbounded/nonpositive denominator intervals
    are unavailable rather than represented as infinities in the archive.
    """
    if type(q) is not int or not 1 <= q <= 500:
        raise ValueError('JOINT_RANK_INVALID')
    d = float(finite(denominator))
    e = float(finite(absolute_error))
    if e < 0:
        raise ValueError('NEGATIVE_DENOMINATOR_ERROR')
    result = dict(nu_lower=None, nu_upper=None, df2_lower=None, df2_upper=None, df2_sign='UNAVAILABLE')
    lo = float(np.nextafter(d - e, -np.inf))
    hi = float(np.nextafter(d + e, np.inf))
    if not np.isfinite(lo) or not np.isfinite(hi):
        raise ArithmeticError('NONFINITE_DF_INTERVAL')
    if lo <= 0 or hi <= 0:
        return result
    numerator = float(q * (q + 1))
    nu_lo = float(np.nextafter(numerator / hi, -np.inf))
    nu_hi = float(np.nextafter(numerator / lo, np.inf))
    df_lo = float(np.nextafter(nu_lo - (q - 1), -np.inf))
    df_hi = float(np.nextafter(nu_hi - (q - 1), np.inf))
    if not np.isfinite([nu_lo, nu_hi, df_lo, df_hi]).all():
        raise ArithmeticError('NONFINITE_DF_INTERVAL')
    sign = 'POSITIVE' if df_lo > 0 else 'NONPOSITIVE' if df_hi <= 0 else 'UNRESOLVED'
    return dict(nu_lower=nu_lo, nu_upper=nu_hi, df2_lower=df_lo, df2_upper=df_hi, df2_sign=sign)

def scalar_denominator(M, E, native_w, *, archived_denominator=None):
    """Enclose scalar contraction at supplied native weights and optional center."""
    w = finite(native_w)
    if w.ndim != 1 or not w.size:
        raise ValueError('SCORING_WEIGHT_DIMENSION')
    moment = _moment(M, E, w.size)
    kvals = []
    kerrors = []
    for a, b in pairs(w.size):
        k = scale(a, b).mul(Ball.exact(w[a])).mul(Ball.exact(w[b]))
        kvals.append(k.value)
        kerrors.append(k.error)
    kv = Ball(np.asarray(kvals).reshape(1, -1), np.asarray(kerrors).reshape(1, -1))
    product = kv.dot(moment)
    terms = kv.mul(product)
    ones = np.ones((terms.value.shape[1], 1))
    bound = add_up(dot_up(terms.error, ones), dot_round(terms.value, ones))
    value = np.sum(terms.value, axis=1).reshape(1, 1)
    ball = _archived_center(Ball(value, bound), archived_denominator)
    return _finish(ball, archived=archived_denominator is not None)

def scalar_denominators(M, E, native_weights, *, archived_denominators=None, block_size=128):
    """Bounded batched replay; native centers remain unchanged, no fitted rows."""
    weights = finite(native_weights)
    if weights.ndim != 2 or not min(weights.shape):
        raise ValueError('SCORING_WEIGHT_DIMENSION')
    if type(block_size) is not int or not 1 <= block_size <= 1024:
        raise ValueError('REPLAY_BLOCK_SIZE_INVALID')
    moment = _moment(M, E, weights.shape[1])
    centers = None
    if archived_denominators is not None:
        centers = finite(archived_denominators)
        if centers.shape != (weights.shape[0],):
            raise ValueError('ARCHIVED_DENOMINATOR_DIMENSION')
    results = []
    for first in range(0, weights.shape[0], block_size):
        last = min(first + block_size, weights.shape[0])
        w = weights[first:last]
        kvals = []
        kerrors = []
        for a, b in pairs(weights.shape[1]):
            k = scale(a, b).mul(Ball.exact(w[:, a])).mul(Ball.exact(w[:, b]))
            kvals.append(k.value)
            kerrors.append(k.error)
        kv = Ball(np.asarray(kvals).T, np.asarray(kerrors).T)
        terms = kv.mul(kv.dot(moment))
        ones = np.ones((terms.value.shape[1], 1))
        error = add_up(dot_up(terms.error, ones), dot_round(terms.value, ones))
        ball = Ball(np.sum(terms.value, axis=1).reshape(-1, 1), error)
        if centers is not None:
            ball = recenter(centers[first:last].reshape(-1, 1), ball)
        for index in range(last - first):
            results.append(_finish(Ball(ball.value[index:index + 1], ball.error[index:index + 1]), archived=centers is not None))
    return results

def joint_denominator(M, E, native_normalized_weights, *, archived_denominator=None):
    """2*trace(S(Wn) M S(Wn)'); no SVD/weight reconstruction is performed here."""
    wn = finite(native_normalized_weights)
    if wn.ndim != 2 or not min(wn.shape) or wn.shape[0] > wn.shape[1]:
        raise ValueError('JOINT_WEIGHT_DIMENSION')
    moment = _moment(M, E, wn.shape[1])
    S = sym_square(Ball.exact(wn))
    joint = S.dot(moment).dot(S.T)
    diag = np.diag(joint.value).reshape(1, -1)
    ediag = np.diag(joint.error).reshape(1, -1)
    ones = np.ones((diag.size, 1))
    trace_error = add_up(dot_up(ediag, ones), dot_round(diag, ones))
    central_trace = np.array([[float(np.trace(joint.value))]])
    ball = Ball(central_trace, trace_error).mul(Ball.exact(2.0))
    ball = _archived_center(ball, archived_denominator)
    result = _finish(ball, archived=archived_denominator is not None)
    result.update(joint_df_interval(result['denominator'], result['absolute_error'], wn.shape[0]))
    result['inference_supported'] = bool(result['resolved'] and result['df2_sign'] == 'POSITIVE')
    return result
