"""Verify error bounds on differences between retained floating-point quantities."""
from fractions import Fraction
import math

class CertificateError(ValueError):
    pass

def _reject():
    raise CertificateError('ARITHMETIC_CERTIFICATE_REJECTED')

def _finite(value):
    if isinstance(value, bool):
        _reject()
    try:
        answer = float(value)
    except (TypeError, ValueError, OverflowError):
        _reject()
    if not math.isfinite(answer):
        _reject()
    return answer

def certify_existing_difference(left, right, coefficient, approximation, tolerance):
    """Return an outward binary64 bound on the exact represented-input error.
    Keep the existing approximation; certify against the unchanged finite
    binary64 tolerance. Exact arithmetic is used for the complete subtraction,
    products, sum and error comparison, never a rounded difference or product.
    The returned bound must also satisfy the same tolerance.
    """
    left = tuple((_finite(v) for v in left))
    right = tuple((_finite(v) for v in right))
    coefficient = tuple((_finite(v) for v in coefficient))
    if not 0 < len(left) == len(right) == len(coefficient) <= 10000:
        _reject()
    approximation = _finite(approximation)
    tolerance = _finite(tolerance)
    if tolerance < 0:
        _reject()
    exact = sum(((Fraction(a) - Fraction(z)) * Fraction(b) for a, z, b in zip(left, right, coefficient)), Fraction(0))
    error = abs(Fraction(approximation) - exact)
    if error > Fraction(tolerance):
        _reject()
    bound = float(error)
    if Fraction(bound) < error:
        bound = math.nextafter(bound, math.inf)
    if not math.isfinite(bound) or Fraction(bound) < error or bound > tolerance:
        _reject()
    return bound
