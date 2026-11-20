"""CR2 covariance and degrees of freedom for individual contrasts."""
import numpy as np

class InvalidDesign(ValueError):
    pass

def sym(a):
    return (a + a.T) / 2

def eig_psd(a, tol=1e-10):
    a = np.asarray(a, dtype=float)
    if a.ndim != 2 or a.shape[0] != a.shape[1] or (not np.isfinite(a).all()):
        raise InvalidDesign('MATRIX_INPUT')
    scale = np.linalg.norm(a, 2)
    if scale == 0:
        return (np.zeros(len(a)), np.eye(len(a)))
    if np.linalg.norm(a - a.T, 2) > tol * scale:
        raise InvalidDesign('ASYMMETRIC_INPUT')
    w, u = np.linalg.eigh(sym(a))
    if w[0] < -tol * scale:
        raise InvalidDesign('NON_PSD_INPUT')
    return (np.maximum(w, 0), u)

def power_pd(a, power, tol=1e-12):
    w, u = eig_psd(a)
    if w[-1] <= 0 or w[0] <= tol * w[-1]:
        raise InvalidDesign('ILL_CONDITIONED_PD_MATRIX')
    return sym(u * w ** power @ u.T)

def active_design(grams, rank_tol=1e-10, leverage_margin=1e-10):
    if len(grams) < 2:
        raise InvalidDesign('TOO_FEW_CLUSTERS')
    grams = [np.asarray(g, dtype=float) for g in grams]
    p = grams[0].shape[0]
    for g in grams:
        if g.shape != (p, p):
            raise InvalidDesign('GRAM_DIMENSIONS')
        eig_psd(g)
    total = sum(grams)
    w, u = eig_psd(total)
    if w[-1] <= 0:
        raise InvalidDesign('ZERO_DESIGN_RANK')
    use = w > rank_tol * w[-1]
    basis = u[:, use]
    active = [sym(basis.T @ g @ basis) for g in grams]
    B = np.diag(1 / w[use])
    Bh = np.diag(1 / np.sqrt(w[use]))
    max_leverage = 0.0
    for g in active:
        q, _ = eig_psd(Bh @ g @ Bh)
        max_leverage = max(max_leverage, float(q[-1]))
    if max_leverage >= 1 - leverage_margin:
        raise InvalidDesign('SATURATED_OR_NEAR_SATURATED_CLUSTER')
    return dict(basis=basis, grams=active, B=B, Bh=Bh, rank=int(sum(use)), max_leverage=max_leverage, cluster_count=len(grams))

def check_scores(scores, basis):
    scores = [np.asarray(s, dtype=float) for s in scores]
    for s in scores:
        if s.shape != (basis.shape[0],) or not np.isfinite(s).all():
            raise InvalidDesign('SCORE_INPUT')
        if np.linalg.norm(s - basis @ (basis.T @ s)) > 2e-08 * max(np.linalg.norm(s), np.finfo(float).tiny):
            raise InvalidDesign('SCORE_OUTSIDE_DESIGN_SPACE')
    active = [basis.T @ s for s in scores]
    scale = sum((np.linalg.norm(s) for s in active))
    if np.linalg.norm(sum(active)) > 2e-08 * max(scale, np.finfo(float).tiny):
        raise InvalidDesign('SCORES_NOT_FROM_FITTED_GLS_RESIDUALS')
    return active

def finish(result, adjusted, D, root):
    B = result['B']
    meat = sum((np.outer(s, s) for s in adjusted))
    result.update(adjusted_scores=adjusted, D=D, covariance=sym(B @ meat @ B), root=root)
    return result

def whitened_brl(grams, scores, **kwargs):
    result = active_design(grams, **kwargs)
    B = result['B']
    Bh = result['Bh']
    scores = check_scores(scores, result['basis'])
    adjusted = []
    D = []
    if len(scores) != len(grams):
        raise InvalidDesign('CLUSTER_ALIGNMENT')
    for g, s in zip(result['grams'], scores):
        q, u = eig_psd(Bh @ g @ Bh)
        h = np.sqrt(1 - q)
        f = 1 / (h * (1 + h))
        F = sym(u * f @ u.T)
        T = np.eye(len(B)) + g @ Bh @ F @ Bh
        adjusted.append(T @ s)
        D.append(sym(T @ g))
    return finish(result, adjusted, D, 'WORKING_COVARIANCE_WHITENED_BRL')

def ri_statistics(raw_grams, residual_cross, tau2, sigma2):
    if not np.isfinite([tau2, sigma2]).all() or tau2 < 0 or sigma2 <= 0:
        raise InvalidDesign('WORKING_VARIANCES')
    if len(raw_grams) != len(residual_cross):
        raise InvalidDesign('CLUSTER_ALIGNMENT')
    grams = []
    scores = []
    for H, h in zip(raw_grams, residual_cross):
        H = np.asarray(H, dtype=float)
        h = np.asarray(h, dtype=float)
        eig_psd(H)
        if h.shape != (len(H),) or not np.isfinite(h).all():
            raise InvalidDesign('RAW_CROSS_INPUT')
        n = H[0, 0]
        sx = H[1:, 0]
        if n < 1 or n != round(n):
            raise InvalidDesign('INVALID_CLUSTER_SIZE')
        centered = sym(H[1:, 1:] - np.outer(sx, sx) / n)
        g = centered / sigma2 + np.outer(sx, sx) / (n * (sigma2 + n * tau2))
        score = (h[1:] - sx * h[0] / n) / sigma2 + sx * h[0] / (n * (sigma2 + n * tau2))
        grams.append(sym(g))
        scores.append(score)
    return (grams, scores)

def canonical_adjustment(V, S):
    Vih = power_pd(V, -0.5)
    A = np.eye(len(V))
    iterations = 0
    for step in range(40):
        residual = sym(V - A @ S @ A)
        error = float(np.linalg.norm(Vih @ residual @ Vih, 2))
        if error <= 1e-10:
            break
        Ah = power_pd(A, 0.5)
        Aih = power_pd(A, -0.5)
        T = sym(Ah @ S @ Ah)
        lam, U = eig_psd(T)
        if lam[0] <= 0:
            raise InvalidDesign('LYAPUNOV_DERIVATIVE_NOT_PD')
        rhs = U.T @ Aih @ residual @ Aih @ U
        correction = rhs / (lam[:, None] + lam[None, :])
        delta = sym(Ah @ U @ correction @ U.T @ Ah)
        accepted = False
        for backtrack in range(30):
            candidate = sym(A + delta * 2.0 ** (-backtrack))
            if np.linalg.eigvalsh(candidate)[0] <= 0:
                continue
            candidate_error = float(np.linalg.norm(Vih @ (V - candidate @ S @ candidate) @ Vih, 2))
            if candidate_error < error:
                A = candidate
                accepted = True
                break
        if not accepted:
            break
        iterations += 1
    residual = sym(V - A @ S @ A)
    error = float(np.linalg.norm(Vih @ residual @ Vih, 2))
    if not np.isfinite(error) or error > 2e-08:
        raise InvalidDesign('BRL_REFERENCE_IDENTITY_FAILED')
    return (A, error, iterations)

def canonical_brl(raw_grams, residual_cross, tau2, sigma2, rank_tol=1e-10, leverage_margin=1e-10):
    grams, scores = ri_statistics(raw_grams, residual_cross, tau2, sigma2)
    result = active_design(grams, rank_tol=rank_tol, leverage_margin=leverage_margin)
    basis = result['basis']
    B = result['B']
    scores_active = check_scores(scores, basis)
    transform = np.zeros((basis.shape[0] + 1, basis.shape[1] + 1))
    transform[0, 0] = 1
    transform[1:, 1:] = basis
    adjusted = []
    D = []
    local_ranks = []
    root_errors = []
    refinements = []
    for index, (H, h) in enumerate(zip(raw_grams, residual_cross)):
        H = sym(transform.T @ H @ transform)
        h = transform.T @ h
        w, u = eig_psd(H)
        use = w > rank_tol * w[-1]
        w = w[use]
        u = u[:, use]
        if not len(w):
            raise InvalidDesign('ZERO_LOCAL_SPAN')
        if np.linalg.norm(h - u @ (u.T @ h)) > 2e-08 * max(np.linalg.norm(h), np.finfo(float).tiny):
            raise InvalidDesign('RESIDUAL_CROSS_OUTSIDE_LOCAL_SPAN')
        Rall = np.sqrt(w)[:, None] * u.T
        q1 = Rall[:, 0]
        R = Rall[:, 1:]
        er = u.T @ h / np.sqrt(w)
        V = sigma2 * np.eye(len(w)) + tau2 * np.outer(q1, q1)
        W = power_pd(V, -1)
        S = sym(V - R @ B @ R.T)
        A, error, iterations = canonical_adjustment(V, S)
        root_errors.append(error)
        refinements.append(iterations)
        if not np.allclose(R.T @ W @ er, scores_active[index], rtol=2e-08, atol=1e-10):
            raise InvalidDesign('PROJECTED_SCORE_MISMATCH')
        adjusted.append(R.T @ W @ A @ er)
        D.append(R.T @ W @ A @ R)
        local_ranks.append(len(w))
    result['local_ranks'] = local_ranks
    result['root_errors'] = root_errors
    result['refinement_iterations'] = refinements
    return finish(result, adjusted, D, 'ORIGINAL_SCALE_SYMMETRIC_BRL')

def contrast_df(result, c):
    c = np.asarray(c, dtype=float)
    E = result['basis']
    if c.shape != (E.shape[0],) or not np.isfinite(c).all() or np.linalg.norm(c) == 0:
        raise InvalidDesign('CONTRAST_INPUT')
    ca = E.T @ c
    if np.linalg.norm(c - E @ ca) > 2e-08 * np.linalg.norm(c):
        raise InvalidDesign('NONESTIMABLE_CONTRAST')
    ca = ca / np.linalg.norm(ca)
    B = result['B']
    Bh = result['Bh']
    d = B @ ca
    target = float(ca @ d)
    if not np.isfinite(target) or target <= 0:
        raise InvalidDesign('NONPOSITIVE_REFERENCE_VARIANCE')
    accumulator = np.zeros_like(B)
    off_diagonal = 0.0
    diagonal = 0.0
    qsum = 0.0
    max_share = 0.0
    for g, D in zip(result['grams'], result['D']):
        qi = float(d @ g @ d) / target
        if qi < -1e-09:
            raise InvalidDesign('NEGATIVE_REFERENCE_COMPONENT')
        qi = max(qi, 0)
        qsum += qi
        max_share = max(max_share, qi)
        diagonal += qi * qi
        z = Bh @ D.T @ d / np.sqrt(target)
        cross = float(z @ accumulator @ z)
        if cross < -1e-09:
            raise InvalidDesign('NEGATIVE_REFERENCE_CROSS_TERM')
        off_diagonal += 2 * max(cross, 0)
        accumulator += np.outer(z, z)
    if not np.isclose(qsum, 1, rtol=1e-08, atol=1e-09):
        raise InvalidDesign('REFERENCE_COMPONENT_SUM')
    denominator = diagonal + off_diagonal
    if not np.isfinite(denominator) or denominator <= 0:
        raise InvalidDesign('INVALID_DF_DENOMINATOR')
    df = 1 / denominator
    if df < 1 - 1e-08 or df > result['cluster_count'] * (1 + 1e-08):
        raise InvalidDesign('DF_REFERENCE_BOUNDS')
    return dict(df=df, max_reference_variance_share=max_share, variance=float(E.T @ c @ result['covariance'] @ (E.T @ c)), reference_variance=float(E.T @ c @ B @ (E.T @ c)))
