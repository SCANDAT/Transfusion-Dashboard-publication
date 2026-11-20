"""Evaluate a scalar variance denominator using decimal arithmetic."""
from decimal import Decimal, Context, ROUND_FLOOR, ROUND_CEILING, InvalidOperation, Overflow
import math
import numpy as np
from moment_error_certificate import Ball, finite, pairs
from roundoff_certificate_replay import _finish
METHOD = 'DECIMAL_DIRECTED_NATIVE_CENTER_V1'
ZERO = Decimal(0)
ONE = Decimal(1)

def outward_float(value):
    result = float(value)
    if not math.isfinite(result) or value < 0:
        raise ArithmeticError('DECIMAL_RADIUS_NONFINITE')
    if Decimal.from_float(result) < value:
        result = float(np.nextafter(result, np.inf))
    if not math.isfinite(result):
        raise ArithmeticError('DECIMAL_RADIUS_NONFINITE')
    if Decimal.from_float(result) < value:
        raise ArithmeticError('DECIMAL_RADIUS_ROUNDING_FAILED')
    return result

class DecimalScalarReplay:

    def __init__(self, moment, error, *, precision=80):
        if type(precision) is not int or not 50 <= precision <= 200:
            raise ValueError('DECIMAL_PRECISION_INVALID')
        M, E = (finite(moment), finite(error))
        if M.ndim != 2 or M.shape[0] != M.shape[1] or E.shape != M.shape or np.any(E < 0):
            raise ValueError('DECIMAL_MOMENT_INVALID')
        d = M.shape[0]
        h = (math.isqrt(8 * d + 1) - 1) // 2
        if h < 1 or h * (h + 1) // 2 != d:
            raise ValueError('DECIMAL_DIMENSION_INVALID')
        self.M = M
        self.E = E
        self.h = h
        self.precision = precision
        self.down = Context(prec=precision, rounding=ROUND_FLOOR)
        self.up = Context(prec=precision, rounding=ROUND_CEILING)
        digits = precision - 5
        scale = 10 ** digits
        n = 2 * scale * scale
        root = math.isqrt(n)
        assert root * root <= n < (root + 1) * (root + 1)
        self.root2 = (Decimal((0, tuple(map(int, str(root))), -digits)), Decimal((0, tuple(map(int, str(root + 1))), -digits)))

    def add(self, a, b):
        return (self.down.add(a[0], b[0]), self.up.add(a[1], b[1]))

    def multiply_exact(self, a, b):
        if b >= 0:
            return (self.down.multiply(a[0], b), self.up.multiply(a[1], b))
        return (self.down.multiply(a[1], b), self.up.multiply(a[0], b))

    def multiply(self, a, b):
        lows = [self.down.multiply(x, y) for x in a for y in b]
        highs = [self.up.multiply(x, y) for x in a for y in b]
        return (min(lows), max(highs))

    def replay(self, native_weight, archived_denominator):
        w = finite(native_weight)
        if w.shape != (self.h,):
            raise ValueError('DECIMAL_WEIGHT_INVALID')
        if isinstance(archived_denominator, (bool, np.bool_)):
            raise ValueError('DECIMAL_CENTER_INVALID')
        native = finite(archived_denominator)
        if native.ndim != 0:
            raise ValueError('DECIMAL_CENTER_INVALID')
        center = float(native)
        exact = Decimal.from_float(center)
        dw = [Decimal.from_float(float(x)) for x in w]
        kv = []
        for a, b in pairs(self.h):
            interval = (ONE, ONE) if a == b else self.root2
            kv.append(self.multiply_exact(self.multiply_exact(interval, dw[a]), dw[b]))
        absolute = [max(lo.copy_abs(), hi.copy_abs()) for lo, hi in kv]
        total = (ZERO, ZERO)
        input_error = ZERO
        for i in range(len(kv)):
            row = (ZERO, ZERO)
            row_error = ZERO
            for j in range(len(kv)):
                m = Decimal.from_float(float(self.M[i, j]))
                row = self.add(row, self.multiply_exact(kv[j], m))
                e = Decimal.from_float(float(self.E[i, j]))
                row_error = self.up.add(row_error, self.up.multiply(e, absolute[j]))
            total = self.add(total, self.multiply(kv[i], row))
            input_error = self.up.add(input_error, self.up.multiply(absolute[i], row_error))
        shift = max(ZERO, self.up.subtract(exact, total[0]), self.up.subtract(total[1], exact))
        error = self.up.add(input_error, shift)
        radius = outward_float(error)
        result = _finish(Ball(np.array([[center]]), np.array([[radius]])), archived=True)
        result.update(tight_replay_method=METHOD, decimal_precision=self.precision, center_preserved=True, proof_scope='ARCHIVED_COMPUTED_M_E_AND_EXACT_NATIVE_WEIGHTS')
        return result
