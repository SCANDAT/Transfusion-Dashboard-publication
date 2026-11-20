"""Calculate diagnostics for joint contrasts with cluster-robust CR2 covariance."""
import math
import numpy as np
import cr2_scalar_math as scalar

class JointInputError(ValueError):
    pass

def _array(value, shape=None):
    a = np.asarray(value, dtype=float)
    if shape is not None and a.shape != shape or not np.isfinite(a).all():
        raise JointInputError('INVALID_JOINT_INPUT')
    return a

def _pd_power(a, exponent, reason, tol=1e-12):
    a = _array(a)
    if a.ndim != 2 or a.shape[0] != a.shape[1] or (not len(a)):
        raise JointInputError(reason)
    scale = np.linalg.norm(a, 2)
    if scale == 0 or np.linalg.norm(a - a.T, 2) > 1e-09 * scale:
        raise JointInputError(reason)
    w, u = np.linalg.eigh((a + a.T) / 2)
    if w[0] <= tol * w[-1] or w[-1] <= 0:
        raise JointInputError(reason)
    return u * w ** exponent @ u.T

def normalized_contrasts(result, contrasts, rank_tol=1e-10):
    """Return normalized active contrasts, rejecting redundant/null-space rows."""
    E = _array(result['basis'])
    if E.ndim != 2 or not E.shape[1]:
        raise JointInputError('INVALID_JOINT_INPUT')
    p, r = E.shape
    B = _array(result['B'], (r, r))
    _pd_power(B, 1, 'INVALID_REFERENCE_INFORMATION')
    if not np.allclose(E.T @ E, np.eye(r), rtol=1e-09, atol=1e-09):
        raise JointInputError('INVALID_DESIGN_BASIS')
    C = _array(contrasts)
    if C.ndim != 2 or C.shape[1] != p or C.shape[0] == 0:
        raise JointInputError('INVALID_JOINT_INPUT')
    norms = np.linalg.norm(C, axis=1)
    if np.any(norms == 0):
        raise JointInputError('REDUNDANT_CONSTRAINTS')
    Cscaled = C / norms[:, None]
    Ca = Cscaled @ E
    if np.linalg.norm(Cscaled - Ca @ E.T, 2) > 2e-08 * np.linalg.norm(Cscaled, 2):
        raise JointInputError('NONESTIMABLE_CONTRAST')
    singular = np.linalg.svd(Ca, compute_uv=False)
    q = len(Ca)
    if q > r or singular[-1] <= rank_tol * singular[0]:
        raise JointInputError('REDUNDANT_CONSTRAINTS')
    Bh = _pd_power(B, 0.5, 'INVALID_REFERENCE_INFORMATION')
    U, singular, _ = np.linalg.svd(Ca @ Bh, full_matrices=False)
    if singular[-1] <= 1e-06 * singular[0]:
        raise JointInputError('SINGULAR_REFERENCE_CONTRAST')
    N = U / singular @ U.T
    N = (N + N.T) / 2
    return dict(E=E, B=B, q=q, r=r, row_scales=norms, C_scaled=Cscaled, C_active=Ca, N=N, C_normalized=N @ Ca)

def reference_blocks(result, contrasts):
    """Materialize the q by q by m by m array for small reference calculations."""
    n = normalized_contrasts(result, contrasts)
    q, r = (n['q'], n['r'])
    m = len(result['grams'])
    if m > 512:
        raise JointInputError('REFERENCE_ARRAY_SIZE_LIMIT')
    T = n['B'] @ n['C_normalized'].T
    Bh = _pd_power(n['B'], 0.5, 'INVALID_REFERENCE_INFORMATION')
    G = [_array(g, (r, r)) for g in result['grams']]
    D = [_array(d, (r, r)) for d in result['D']]
    if len(D) != m or m != result['cluster_count'] or m < 2:
        raise JointInputError('CLUSTER_ALIGNMENT')
    L = [T.T @ d @ Bh for d in D]
    blocks = np.empty((q, q, m, m))
    for i in range(m):
        for j in range(m):
            blocks[:, :, i, j] = T.T @ G[i] @ T if i == j else -L[i] @ L[j].T
    return blocks

def symmetric_square(L):
    """Orthogonal symmetric-coordinate representation of A -> L A L'."""
    q, r = L.shape
    a, b = np.triu_indices(q)
    u, v = np.triu_indices(r)
    weights = np.sqrt(2 - (a == b))[:, None] * np.sqrt(2 - (u == v))[None, :]
    return 0.5 * weights * (L[a[:, None], u] * L[b[:, None], v] + L[b[:, None], u] * L[a[:, None], v])

def reference_moments(result, contrasts, *, method='stream', max_bytes=512 * 2 ** 20):
    """Working-Gaussian variance of normalized CR2; no cluster-pair loop by default.

    H_ii=T'G_iT; H_ij=-L_iL_j' for i!=j; L_i=T'D_i B^(1/2).
    Sum_ij [(tr H_ij)^2 + tr(H_ij H_ij)] is the HTZ denominator.
    The second trace is NOT a Frobenius square of a nonsymmetric block.
    Streaming cost is O(m*q^2*r^2), memory O(q^2*r^2), not O(m^2).
    """
    n = normalized_contrasts(result, contrasts)
    q, r, B = (n['q'], n['r'], n['B'])
    T = B @ n['C_normalized'].T
    Bh = _pd_power(B, 0.5, 'INVALID_REFERENCE_INFORMATION')
    m = len(result['grams'])
    if len(result['D']) != m or m != result['cluster_count'] or m < 2:
        raise JointInputError('CLUSTER_ALIGNMENT')
    if method not in ('stream', 'symmetric', 'pairs'):
        raise JointInputError('INVALID_MOMENT_METHOD')
    elements = (q * r) ** 2 if method == 'stream' else q * (q + 1) * r * (r + 1) // 4
    if method != 'pairs' and 4 * 8 * elements > max_bytes:
        raise JointInputError('JOINT_ACCUMULATOR_SIZE_LIMIT')
    diag_sum = np.zeros((q, q))
    terms = []
    if method == 'stream':
        accumulator = np.zeros((q, r, q, r))
        compensation = np.zeros_like(accumulator)
    elif method == 'symmetric':
        accumulator = np.zeros((q * (q + 1) // 2, r * (r + 1) // 2))
        compensation = np.zeros_like(accumulator)
    else:
        if m > 512:
            raise JointInputError('REFERENCE_ARRAY_SIZE_LIMIT')
        prior = []
    for g, d in zip(result['grams'], result['D']):
        g, d = (_array(g, (r, r)), _array(d, (r, r)))
        H = T.T @ g @ T
        if not np.allclose(H, H.T, rtol=1e-09, atol=1e-10):
            raise JointInputError('ASYMMETRIC_REFERENCE_COMPONENT')
        if np.linalg.eigvalsh((H + H.T) / 2)[0] < -1e-09:
            raise JointInputError('NEGATIVE_REFERENCE_COMPONENT')
        diag_sum += H
        terms.append(float(np.trace(H) ** 2 + np.trace(H @ H)))
        L = T.T @ d @ Bh
        if method == 'stream':
            a = np.einsum('ar,arbs,bs->', L, accumulator, L, optimize=True)
            b = np.einsum('as,arbs,br->', L, accumulator, L, optimize=True)
            terms.append(2 * float(a + b))
            update = np.einsum('ar,bs->arbs', L, L) - compensation
            fresh = accumulator + update
            compensation = fresh - accumulator - update
            accumulator = fresh
        elif method == 'symmetric':
            K = symmetric_square(L)
            terms.append(4 * float(np.sum(accumulator * K)))
            update = K - compensation
            fresh = accumulator + update
            compensation = fresh - accumulator - update
            accumulator = fresh
        else:
            for previous in prior:
                Hcross = -L @ previous.T
                terms.append(2 * float(np.trace(Hcross) ** 2 + np.trace(Hcross @ Hcross)))
            prior.append(L)
    if not np.allclose(diag_sum, np.eye(q), rtol=2e-08, atol=1e-09):
        raise JointInputError('REFERENCE_EXPECTATION_NOT_IDENTITY')
    denominator = math.fsum(terms)
    if not np.isfinite(denominator) or denominator <= 0:
        raise JointInputError('INVALID_HTZ_MOMENT')
    cancellation = math.fsum((abs(x) for x in terms)) / denominator
    if cancellation > 100000000.0:
        raise JointInputError('UNSTABLE_HTZ_MOMENT_CANCELLATION')
    nu = q * (q + 1) / denominator
    n.update(denominator=denominator, nu=float(nu), df_num=q, df_denom=float(nu - q + 1), cancellation_ratio=cancellation)
    return n

def joint_test(result, contrasts, beta, null=None, *, method='stream', low_df=4):
    """Calculate the HTZ F statistic and effective denominator degrees of freedom.

    A nonpositive denominator leaves F undefined. A small positive value is
    flagged and retained. Hypotheses must have full row rank. The calling
    analysis evaluates the F distribution for an available statistic.
    """
    try:
        n = reference_moments(result, contrasts, method=method)
        q, r, E = (n['q'], n['r'], n['E'])
        beta = _array(beta, (E.shape[0],))
        null = np.zeros(q) if null is None else _array(null, (q,))
        V = _array(result['covariance'], (r, r))
        Cn = n['C_normalized']
        Vc = Cn @ V @ Cn.T
        inverse = _pd_power(Vc, -1, 'SINGULAR_OBSERVED_CONTRAST_COVARIANCE')
        theta = n['N'] @ (n['C_scaled'] @ beta - null / n['row_scales'])
        wald = float(theta @ inverse @ theta)
        if not np.isfinite(wald) or wald < 0:
            raise JointInputError('INVALID_WALD_STATISTIC')
        base = dict(method='CR2_HTZ_DIAGNOSTIC', wald=wald, q=q, nu=n['nu'], df_num=q, df_denom=n['df_denom'], denominator=n['denominator'], p_value=None, p_value_status='VERIFIED_F_CDF_REQUIRED', scientific_approval='INDEPENDENT_VALIDATION_REQUIRED')
        if n['df_denom'] <= 0:
            return dict(base, status='NONPOSITIVE_HTZ_DF', F=None, delta=None)
        delta = n['df_denom'] / n['nu']
        return dict(base, status='LOW_EFFECTIVE_DF' if n['df_denom'] < low_df else 'COMPUTED', F=delta * wald / q, delta=delta)
    except (JointInputError, scalar.InvalidDesign) as exc:
        return dict(status=str(exc), method='CR2_HTZ_DIAGNOSTIC', F=None, p_value=None, scientific_approval='INDEPENDENT_VALIDATION_REQUIRED')

def svec(a):
    """Isometric upper-triangle coordinates for symmetric matrices."""
    i, j = np.triu_indices(a.shape[-1])
    return a[..., i, j] * np.sqrt(2 - (i == j))

def contrast_moment_archive(result, contrasts, *, method='fast', max_bytes=512 * 2 ** 20):
    """Construct the fourth-moment operator for a span of contrasts.

    M=half Cov_working[svec(Vhat_normalized)] is d by d, d=h(h+1)/2.
    A future scalar row w has Satterthwaite denominator svec(ww')' M svec(ww').
    Fast mode sums K_i, then uses symmetric-square multiplicativity to remove
    self-pairs. Stable mode accumulates cross-terms per cluster and serves as
    an independent numerical check.
    """
    n = normalized_contrasts(result, contrasts)
    h, r, B = (n['q'], n['r'], n['B'])
    d = h * (h + 1) // 2
    dr = r * (r + 1) // 2
    if method not in ('fast', 'stable'):
        raise JointInputError('INVALID_MOMENT_METHOD')
    if 8 * (4 * d * dr + 6 * d * d) > max_bytes:
        raise JointInputError('MOMENT_ARCHIVE_SIZE_LIMIT')
    T = B @ n['C_normalized'].T
    Bh = _pd_power(B, 0.5, 'INVALID_REFERENCE_INFORMATION')
    if len(result['grams']) != len(result['D']) or len(result['D']) != result['cluster_count']:
        raise JointInputError('CLUSTER_ALIGNMENT')
    Ksum = np.zeros((d, dr))
    Kcomp = np.zeros_like(Ksum)
    Msum = np.zeros((d, d))
    Mcomp = np.zeros_like(Msum)
    correction = np.zeros((d, d))
    correction_comp = np.zeros_like(correction)
    reference = np.zeros((h, h))
    norm_budget = 0.0
    for g, D in zip(result['grams'], result['D']):
        H = T.T @ _array(g, (r, r)) @ T
        L = T.T @ _array(D, (r, r)) @ Bh
        reference += H
        K = symmetric_square(L)
        diagonal = symmetric_square(H)
        if method == 'stable':
            cross = K @ Ksum.T
            increment = diagonal + cross + cross.T
            norm_budget += float(np.linalg.norm(diagonal, 'fro') + 2 * np.linalg.norm(cross, 'fro'))
        else:
            increment = diagonal
            remove = symmetric_square(L @ L.T)
            z = remove - correction_comp
            fresh = correction + z
            correction_comp = fresh - correction - z
            correction = fresh
            norm_budget += float(np.linalg.norm(diagonal, 'fro') + np.linalg.norm(remove, 'fro'))
        z = increment - Mcomp
        fresh = Msum + z
        Mcomp = fresh - Msum - z
        Msum = fresh
        z = K - Kcomp
        fresh = Ksum + z
        Kcomp = fresh - Ksum - z
        Ksum = fresh
    if not np.allclose(reference, np.eye(h), rtol=2e-08, atol=1e-09):
        raise JointInputError('REFERENCE_EXPECTATION_NOT_IDENTITY')
    if method == 'fast':
        all_pairs = Ksum @ Ksum.T
        Msum = Msum + all_pairs - correction
        norm_budget += float(np.linalg.norm(all_pairs, 'fro'))
    Msum = (Msum + Msum.T) / 2
    roundoff_envelope = np.finfo(float).eps * (64 + 8 * len(result['D'])) * norm_budget
    if np.linalg.eigvalsh(Msum)[0] < -roundoff_envelope:
        raise JointInputError('NON_PSD_GAUSSIAN_MOMENT_OPERATOR')
    V = n['C_normalized'] @ result['covariance'] @ n['C_normalized'].T
    return dict(moment_half_covariance=Msum, reference_covariance=np.eye(h), robust_covariance=(V + V.T) / 2, weight_transform=np.linalg.solve(n['N'].T, np.diag(n['row_scales'])), contrast_basis=n['C_normalized'] @ n['E'].T, roundoff_envelope=roundoff_envelope, method=method, cluster_count=result['cluster_count'], span_dimension=h, moment_dimension=d, scientific_approval='INDEPENDENT_VALIDATION_REQUIRED')

def scalar_df_from_archive(archive, weights):
    """All weights must represent nonzero contrasts in the archived span."""
    weights = _array(weights)
    h = archive['span_dimension']
    if weights.ndim != 2 or weights.shape[1] != h:
        raise JointInputError('INVALID_ARCHIVE_WEIGHTS')
    w = weights @ archive['weight_transform'].T
    target = np.einsum('ni,ij,nj->n', w, archive['reference_covariance'], w)
    if np.any(target <= 0):
        raise JointInputError('ZERO_CONTRAST_HAS_NO_SATTERTHWAITE_DF')
    k = svec(w[:, :, None] * w[:, None, :])
    denominator = np.einsum('ni,ij,nj->n', k, archive['moment_half_covariance'], k, optimize=True)
    envelope = archive['roundoff_envelope'] * np.sum(k * k, axis=1)
    if np.any(denominator <= 0) or np.any(envelope > 2e-08 * denominator):
        raise JointInputError('MOMENT_ARCHIVE_NUMERICAL_SUPPORT_UNRESOLVED')
    return dict(df=target ** 2 / denominator, variance=np.einsum('ni,ij,nj->n', w, archive['robust_covariance'], w), reference_variance=target, denominator=denominator)

def htz_from_archive(archive, weights):
    """Moment/DF part of any full-row-rank joint hypothesis in saved span."""
    weights = _array(weights)
    if weights.ndim != 2 or weights.shape[1] != archive['span_dimension']:
        raise JointInputError('INVALID_ARCHIVE_WEIGHTS')
    w = weights @ archive['weight_transform'].T
    q = len(w)
    normalize = _pd_power(w @ archive['reference_covariance'] @ w.T, -0.5, 'REDUNDANT_CONSTRAINTS')
    S = symmetric_square(normalize @ w)
    M = S @ archive['moment_half_covariance'] @ S.T
    denominator = 2 * float(np.trace(M))
    envelope = archive['roundoff_envelope'] * float(np.sum(S * S))
    if denominator <= 0 or envelope > 2e-08 * denominator:
        raise JointInputError('MOMENT_ARCHIVE_NUMERICAL_SUPPORT_UNRESOLVED')
    nu = q * (q + 1) / denominator
    return dict(nu=nu, df_denom=nu - q + 1, df_num=q, denominator=denominator)
