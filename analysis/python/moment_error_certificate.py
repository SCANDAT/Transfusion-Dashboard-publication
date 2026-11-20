"""Propagate floating-point error bounds through moment calculations."""
from dataclasses import dataclass
import math
import numpy as np
U = 2.0 ** (-53)
ETA = float.fromhex('0x0.0000000000001p-1022')
INF = float('inf')

def finite(a):
    a = np.asarray(a, dtype=float)
    if not np.isfinite(a).all():
        raise ArithmeticError('NONFINITE_CERTIFICATE')
    return a

def up(a):
    """Upward enclosure of one rounded nonnegative operation."""
    a = finite(a)
    if np.any(a < 0):
        raise ArithmeticError('NEGATIVE_ERROR_BOUND')
    return finite(np.nextafter(a, INF))

def add_up(a, b):
    a, b = np.broadcast_arrays(a, b)
    z = up(a + b)
    return np.where((a == 0) & (b == 0), 0.0, z)

def mul_up(a, b):
    a, b = np.broadcast_arrays(a, b)
    z = up(a * b)
    return np.where((a == 0) | (b == 0), 0.0, z)

def gamma(n):
    if n * U >= 0.25:
        raise ArithmeticError('OPERATION_COUNT_LIMIT')
    return float(up(n * U / (1.0 - n * U)))

def local_round(z):
    """|fl(exact)-exact| <= u/(1-u)*|fl(exact)| + eta.

    Eta is one smallest subnormal, larger than the half-eta underflow term.
    No relative-only assumption near zero is made.
    """
    return add_up(mul_up(gamma(1), np.abs(finite(z))), ETA)

def dot_round(a, b):
    """Bound a dot product's rounding including gradual underflow.

    At most 2*n rounded operations occur on any dependency path. The absolute
    product sum is itself bounded outward. This overbounds ordinary, pairwise,
    or FMA dot products; overflow fails closed.
    """
    a, b = (finite(a), finite(b))
    n = a.shape[-1]
    g = gamma(2 * n)
    subnormal = float(mul_up(2 * n, up(ETA / (1 - 2 * n * U))))
    absolute_fl = finite(np.abs(a) @ np.abs(b))
    denominator_lo = np.nextafter(1 - g, -INF)
    absolute_hi = up(add_up(absolute_fl, subnormal) / denominator_lo)
    return add_up(mul_up(g, absolute_hi), subnormal)

def dot_up(a, b):
    """Upper bound for exact product of nonnegative matrices."""
    a, b = (finite(a), finite(b))
    if np.any(a < 0) or np.any(b < 0):
        raise ArithmeticError('NEGATIVE_ERROR_BOUND')
    return add_up(finite(a @ b), dot_round(a, b))

@dataclass
class Ball:
    value: np.ndarray
    error: np.ndarray

    def __post_init__(self):
        self.value = finite(self.value)
        self.error = np.broadcast_to(finite(self.error), self.value.shape).copy()
        if np.any(self.error < 0):
            raise ArithmeticError('NEGATIVE_ERROR_BOUND')

    @classmethod
    def exact(cls, value):
        v = finite(value)
        return cls(v, np.zeros(v.shape))

    def take(self, index):
        return Ball(self.value[index], self.error[index])

    @property
    def T(self):
        return Ball(self.value.T, self.error.T)

    def add(self, other, sign=1):
        v = finite(self.value + sign * other.value)
        return Ball(v, add_up(add_up(self.error, other.error), local_round(v)))

    def mul(self, other):
        v = finite(self.value * other.value)
        e = add_up(mul_up(np.abs(self.value), other.error), mul_up(np.abs(other.value), self.error))
        e = add_up(e, mul_up(self.error, other.error))
        return Ball(v, add_up(e, local_round(v)))

    def dot(self, other):
        v = finite(self.value @ other.value)
        e = add_up(dot_up(np.abs(self.value), other.error), dot_up(self.error, np.abs(other.value)))
        e = add_up(e, dot_up(self.error, other.error))
        return Ball(v, add_up(e, dot_round(self.value, other.value)))

def pairs(n):
    return [(a, b) for a in range(n) for b in range(a, n)]

def scale(a, b):
    if a == b:
        return Ball.exact(1.0)
    root = math.sqrt(2.0)
    if root.hex() != '0x1.6a09e667f3bcdp+0':
        raise ArithmeticError('UNSUPPORTED_SQRT_HOST')
    return Ball(root, math.ulp(root))

def sym_square(mat):
    """Same order as cr2SymSquarePairs; enclose exact sqrt(2)."""
    pa, pb = (pairs(mat.value.shape[0]), pairs(mat.value.shape[1]))
    v, e = (np.empty((len(pa), len(pb))), np.empty((len(pa), len(pb))))
    for row, (a, b) in enumerate(pa):
        for col, (u, z) in enumerate(pb):
            factor = Ball.exact(0.5).mul(scale(a, b)).mul(scale(u, z))
            s = mat.take((a, u)).mul(mat.take((b, z))).add(mat.take((b, u)).mul(mat.take((a, z))))
            result = factor.mul(s)
            v[row, col], e[row, col] = (result.value, result.error)
    return Ball(v, e)

class KahanBall:
    """Existing Kahan values with an a posteriori certificate.

    Let A_i/B_i/C_i/D_i be local rounding errors in corrected/fresh/difference/
    compensation. Algebra gives c_i=B_i+C_i+D_i and
      t_n - sum(x_i) = B_n + sum(A_i) - sum_{i<n}(C_i+D_i).
    Hence sum of bounds on A,C,D plus final B encloses the summation error.
    All positive bounds are accumulated outward; input errors are separate.
    No heuristic Kahan constant, Sterbenz assumption or small-n approximation.
    """

    def __init__(self, shape):
        self.total = np.zeros(shape)
        self.comp = np.zeros(shape)
        self.accumulated = np.zeros(shape)
        self.last_addition = np.zeros(shape)
        self.input_error = np.zeros(shape)

    def add(self, item):
        corrected = finite(item.value - self.comp)
        fresh = finite(self.total + corrected)
        difference = finite(fresh - self.total)
        comp = finite(difference - corrected)
        local = add_up(local_round(corrected), local_round(difference))
        local = add_up(local, local_round(comp))
        self.accumulated = add_up(self.accumulated, local)
        self.input_error = add_up(self.input_error, item.error)
        self.last_addition = local_round(fresh)
        self.total, self.comp = (fresh, comp)

    def result(self):
        error = add_up(self.input_error, self.accumulated)
        return Ball(self.total, add_up(error, self.last_addition))

def build_moment(h_list, l_list):
    """Certified FAST M plus unchanged old global envelope."""
    if len(h_list) != len(l_list) or len(h_list) < 2:
        raise ValueError('CLUSTER_ALIGNMENT')
    h, r = (h_list[0].shape[0], l_list[0].shape[1])
    d, dr = (h * (h + 1) // 2, r * (r + 1) // 2)
    diagonal, correction = (KahanBall((d, d)), KahanBall((d, d)))
    ksum = KahanBall((d, dr))
    budget = 0.0
    for hh, ll in zip(h_list, l_list):
        H, L = (Ball.exact(hh), Ball.exact(ll))
        dd = sym_square(H)
        rr = sym_square(L.dot(L.T))
        diagonal.add(dd)
        correction.add(rr)
        ksum.add(sym_square(L))
        budget += np.linalg.norm(dd.value) + np.linalg.norm(rr.value)
    K = ksum.result()
    all_pairs = K.dot(K.T)
    M = diagonal.result().add(all_pairs).add(correction.result(), sign=-1)
    M = M.add(M.T).mul(Ball.exact(0.5))
    old_envelope = 2 * U * (64 + 8 * len(h_list)) * (budget + np.linalg.norm(all_pairs.value))
    return (M, old_envelope)

def scalar_denominator(moment, w):
    """Covers k construction, M construction and contraction."""
    w = finite(w)
    k = [scale(a, b).mul(Ball.exact(w[a])).mul(Ball.exact(w[b])) for a, b in pairs(w.size)]
    row = Ball(np.array([x.value for x in k]).reshape(1, -1), np.array([x.error for x in k]).reshape(1, -1))
    return row.dot(moment).dot(row.T)
