"""Check symmetry, definiteness and floating-point error in covariance calculations."""
from __future__ import annotations
from dataclasses import dataclass
from fractions import Fraction
import math
import sys
import numpy as np

class CovarianceNumericalError(ValueError):

    def __init__(self, code):
        self.code = code
        super().__init__(code)

def _need(ok, code):
    if not ok:
        raise CovarianceNumericalError(code)

def _real(value):
    try:
        value = float(value)
    except (TypeError, ValueError, OverflowError):
        raise CovarianceNumericalError('NONFINITE_NUMERICAL_INPUT') from None
    _need(math.isfinite(value), 'NONFINITE_NUMERICAL_INPUT')
    return value

def _tol(value):
    value = _real(value)
    _need(0 < value < 1, 'INVALID_RELATIVE_TOLERANCE')
    return Fraction(value)

def _error(value):
    value = _real(value)
    _need(value >= 0, 'INVALID_ABSOLUTE_ERROR_BOUND')
    return Fraction(value)

def _rounded_float(value):
    try:
        result = float(value)
    except OverflowError:
        raise CovarianceNumericalError('NUMERICAL_BOUND_NOT_FINITE') from None
    _need(math.isfinite(result), 'NUMERICAL_BOUND_NOT_FINITE')
    return result

def _upper_float(value):
    result = _rounded_float(value)
    if Fraction(result) < value:
        result = math.nextafter(result, math.inf)
    _need(math.isfinite(result), 'NUMERICAL_BOUND_NOT_FINITE')
    return result

def _ulp_error(value):
    return Fraction(0) if value == 0 else 4 * Fraction(math.ulp(value))

@dataclass(frozen=True)
class ReconstructionCertificate:
    status: str
    absolute_residual: float
    absolute_roundoff_bound: float
    relative_allowance: float
    reconstructed: float

def check_variance_se(variance, standard_error, *, rtol=1e-08):
    """Strict relative comparison to SE squared; no unit-scale absolute floor."""
    v = _real(variance)
    se = _real(standard_error)
    tol = _tol(rtol)
    _need(v >= 0 and se >= 0, 'NEGATIVE_VARIANCE_OR_SE')
    if v == 0 or se == 0:
        _need(v == 0 and se == 0, 'VARIANCE_SE_MISMATCH')
        return
    vv = Fraction(v)
    ss = Fraction(se) ** 2
    _need(abs(vv - ss) <= tol * max(vv, ss), 'VARIANCE_SE_MISMATCH')

def _normalised(value, sd_a, sd_b):
    return _rounded_float(Fraction(float(value)) / (Fraction(float(sd_a)) * Fraction(float(sd_b))))

def check_covariance_entry(left, right, sd_a, sd_b, *, rtol=1e-08):
    """Agreement relative to marginal SD product, including near-zero covariances."""
    a = _real(left)
    b = _real(right)
    sa = _real(sd_a)
    sb = _real(sd_b)
    tol = _tol(rtol)
    _need(sa >= 0 and sb >= 0, 'NEGATIVE_VARIANCE_OR_SE')
    if sa == 0 or sb == 0:
        _need(a == 0 and b == 0, 'NONZERO_ZERO_VARIANCE_ROW')
        return
    _need(abs(Fraction(a) - Fraction(b)) <= tol * Fraction(sa) * Fraction(sb), 'COVARIANCE_ENTRY_MISMATCH')

def check_covariance_matrix(matrix, standard_errors=None, *, symmetry_rtol=1e-08, psd_rtol=1e-08):
    """PSD/symmetry on marginal-SD scale, with exact canonical zero rows.

    Eigenvalues are checked in dimensionless correlation coordinates. This is a
    floating-point PSD certificate at the declared tolerance, not an eigenvalue
    truncation or permission to modify the supplied covariance.
    """
    try:
        mat = np.asarray(matrix, dtype=float)
    except (TypeError, ValueError):
        raise CovarianceNumericalError('COVARIANCE_MATRIX_SCHEMA') from None
    _need(mat.ndim == 2 and mat.shape[0] == mat.shape[1] and (1 <= len(mat) <= 256), 'COVARIANCE_MATRIX_SCHEMA')
    _need(bool(np.isfinite(mat).all()), 'NONFINITE_NUMERICAL_INPUT')
    _need(bool(np.all(np.diag(mat) >= 0)), 'NEGATIVE_VARIANCE_OR_SE')
    symtol = float(_tol(symmetry_rtol))
    psdtol = float(_tol(psd_rtol))
    if standard_errors is None:
        sd = np.sqrt(np.diag(mat))
    else:
        try:
            sd = np.asarray(standard_errors, dtype=float)
        except (TypeError, ValueError):
            raise CovarianceNumericalError('STANDARD_ERROR_SCHEMA') from None
        _need(sd.shape == (len(mat),), 'STANDARD_ERROR_SCHEMA')
        for v, se in zip(np.diag(mat), sd):
            check_variance_se(v, se)
    zero = np.flatnonzero(sd == 0)
    for i in zero:
        _need(bool(np.all(mat[i, :] == 0) and np.all(mat[:, i] == 0)), 'NONZERO_ZERO_VARIANCE_ROW')
    active = np.flatnonzero(sd > 0)
    if not len(active):
        return
    corr = np.array([[_normalised(mat[i, j], sd[i], sd[j]) for j in active] for i in active])
    _need(float(np.max(np.abs(corr - corr.T))) <= symtol, 'COVARIANCE_ASYMMETRIC')
    symmetric = (corr + corr.T) * 0.5
    try:
        eig = np.linalg.eigvalsh(symmetric)
    except np.linalg.LinAlgError:
        raise CovarianceNumericalError('COVARIANCE_EIGENSYSTEM_FAILED') from None
    reference = max(1.0, float(np.max(np.abs(eig))))
    _need(float(np.min(eig)) >= -psdtol * reference, 'COVARIANCE_NOT_PSD')

def covariance_dot_error(sd_left, sd_right, terms):
    """Conservative binary64 dot-product/scaling error from marginal norms.

    Assumes a common set of fixed person scores, at most terms products, and
    ordinary dot-product summation plus scalar scaling. gamma_(2G+8) uses eps
    (twice unit roundoff); Cauchy bounds sum(abs(products)) by marginal norms.
    Division by1-gamma accounts for norm underestimation at that bound.
    This is NOT a bound on errors creating scores from patient observations.
    """
    sa = _real(sd_left)
    sb = _real(sd_right)
    _need(sa >= 0 and sb >= 0, 'NEGATIVE_VARIANCE_OR_SE')
    _need(isinstance(terms, (int, np.integer)) and (not isinstance(terms, bool)) and (1 <= terms <= 2 ** 53), 'INVALID_DOT_PRODUCT_LENGTH')
    neps = Fraction(2 * int(terms) + 8) * Fraction(sys.float_info.epsilon)
    _need(neps < Fraction(1, 1000), 'ROUNDING_BOUND_UNRESOLVED')
    gamma = neps / (1 - neps)
    return _upper_float(gamma / (1 - gamma) * Fraction(sa) * Fraction(sb))

def _certificate(actual, operands, weights, operand_errors, actual_error, rtol, require_resolved, actual_roundoff):
    tol = _tol(rtol)
    values = [_real(x) for x in operands]
    coefs = [_real(x) for x in weights]
    _need(len(values) == len(coefs) and 0 < len(values) <= 256, 'LINEAR_RECONSTRUCTION_SCHEMA')
    if operand_errors is None:
        errors = [Fraction(0)] * len(values)
    else:
        _need(len(operand_errors) == len(values), 'LINEAR_RECONSTRUCTION_SCHEMA')
        errors = [_error(x) for x in operand_errors]
    predicted = sum((Fraction(w) * Fraction(v) for w, v in zip(coefs, values)), Fraction(0))
    allowance = _error(actual_error) + actual_roundoff
    for v, w, e in zip(values, coefs, errors):
        allowance += abs(Fraction(w)) * (e + _ulp_error(v))
    residual = abs(actual - predicted)
    relative = tol * max(abs(actual), abs(predicted))
    _need(residual <= allowance + relative, 'LINEAR_RECONSTRUCTION_MISMATCH')
    resolved = allowance <= relative if relative > 0 else allowance == 0
    if require_resolved:
        _need(resolved, 'RECONSTRUCTION_CANCELLATION_LIMITED')
    return ReconstructionCertificate('RESOLVED' if resolved else 'CANCELLATION_LIMITED', _upper_float(residual), _upper_float(allowance), _upper_float(relative), _rounded_float(predicted))

def check_linear_reconstruction(actual, operands, weights, *, operand_errors=None, actual_error=0.0, rtol=1e-08, require_resolved=False):
    """Check a linear identity with explicit rounding/cancellation accounting.

    Four-ULP allowances on supplied binary64 values are a declared local final
    rounding allowance, not proof of lossless E32 serialization. The installed
    export/parser error must be verified or added to the explicit error bounds.
    Caller-supplied operand/actual errors are additive source arithmetic bounds.
    Exact rational evaluation adds no summation cancellation to the reference.
    CANCELLATION_LIMITED means only agreement within those absolute bounds; it
    cannot certify the tiny reconstructed result to the requested relative error.
    """
    value = _real(actual)
    return _certificate(Fraction(value), operands, weights, operand_errors, actual_error, rtol, require_resolved, _ulp_error(value))

def check_pairwise_variance(standard_error, var_a, var_b, cov_ab, *, operand_errors=None, actual_error=0.0, rtol=1e-08, require_resolved=False):
    """Check SE(A-B)^2=Var(A)+Var(B)-2Cov(A,B), retaining tiny positive SEs.

    This does not replace separate strict diagonal-vs-marginal-SE checks. When
    cancellation-limited, exported covariance cannot independently certify the
    relative accuracy of the pairwise variance; source/direct tests are needed.
    """
    se = _real(standard_error)
    _need(se > 0, 'PAIRWISE_SE_NOT_POSITIVE')
    a = _real(var_a)
    b = _real(var_b)
    ab = _real(cov_ab)
    _need(a >= 0 and b >= 0, 'NEGATIVE_VARIANCE_OR_SE')
    fs = Fraction(se)
    delta = _ulp_error(se)
    return _certificate(fs * fs, [a, b, ab], [1.0, 1.0, -2.0], operand_errors, actual_error, rtol, require_resolved, 2 * abs(fs) * delta + delta * delta)
