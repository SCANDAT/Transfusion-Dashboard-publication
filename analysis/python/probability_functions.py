"""Incomplete beta probabilities for independent inference checks."""
import math


def beta_cf(a, b, x):
    tiny = 1e-300
    qab, qap, qam = (a + b, a + 1, a - 1)
    c, d = (1.0, 1 - qab * x / qap)
    if abs(d) < tiny:
        d = tiny
    d = 1 / d
    h = d
    for m in range(1, 301):
        mm = 2 * m
        aa = m * (b - m) * x / ((qam + mm) * (a + mm))
        d = 1 + aa * d
        c = 1 + aa / c
        if abs(d) < tiny:
            d = tiny
        if abs(c) < tiny:
            c = tiny
        d = 1 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + mm) * (qap + mm))
        d = 1 + aa * d
        c = 1 + aa / c
        if abs(d) < tiny:
            d = tiny
        if abs(c) < tiny:
            c = tiny
        d = 1 / d
        delta = d * c
        h *= delta
        if abs(delta - 1) < 2e-14:
            return h
    raise ValueError('BETA_CONVERGENCE')


def ibeta(a, b, x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    front = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1) / (a + b + 2):
        return front * beta_cf(a, b, x) / a
    return 1 - front * beta_cf(b, a, 1 - x) / b
