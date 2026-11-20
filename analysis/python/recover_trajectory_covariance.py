"""Reconstruct trajectory covariance from a fitted model archive."""
from dataclasses import dataclass
import numpy as np

class ArchiveError(ValueError):
    pass

@dataclass(frozen=True)
class TrajectoryArchive:
    anchor_mean: np.ndarray
    anchor_covariance: np.ndarray
    grid_weights: np.ndarray
    design_rank: int
    maximum_design_error: float
    maximum_prediction_error: float
    maximum_se_error: float
    minimum_covariance_eigenvalue: float
    direct_contrasts_checked: int

    def contrast(self, grid_coefficients):
        c = np.asarray(grid_coefficients, dtype=float)
        if c.shape != (len(self.grid_weights),) or not np.isfinite(c).all():
            raise ArchiveError('Contrast must have one finite coefficient per grid row')
        a = c @ self.grid_weights
        estimate = float(a @ self.anchor_mean)
        variance = float(a @ self.anchor_covariance @ a)
        roundoff_bound = 64 * np.finfo(float).eps * float(np.abs(a) @ np.abs(self.anchor_covariance) @ np.abs(a))
        if variance < -roundoff_bound:
            raise ArchiveError('Negative contrast variance exceeds numerical tolerance')
        return (estimate, float(np.sqrt(max(0.0, variance))))

def reconstruct(anchor_mean, anchor_se, differences, anchor_design, grid_design, grid_prediction, grid_se, *, direct_contrasts, design_tolerance=1e-10, result_rtol=1e-07, result_atol=1e-12):
    """differences: exactly one (i,j,estimate,se) for every 0-based i<j.

    direct_contrasts contains (grid coefficient vector, SAS estimate, SAS SE).
    Include every exported within-category and between-category endpoint contrast.
    Its sign is anchor_i minus anchor_j. Duplicate, absent or reversed pairs
    are rejected. Designs must use identical explicitly ordered SAS columns.
    No ridge, smoothing or covariance repair is performed.
    """
    for tolerance in [design_tolerance, result_rtol, result_atol]:
        if not np.isfinite(tolerance) or tolerance < 0:
            raise ArchiveError('Tolerances must be finite and nonnegative')
    mu = np.array(anchor_mean, dtype=float, copy=True)
    se = np.asarray(anchor_se, dtype=float)
    a = np.asarray(anchor_design, dtype=float)
    g = np.asarray(grid_design, dtype=float)
    pred = np.asarray(grid_prediction, dtype=float)
    grid_se = np.asarray(grid_se, dtype=float)
    if mu.ndim != 1 or len(mu) < 2 or se.shape != mu.shape:
        raise ArchiveError('At least two matching anchor means and SEs are required')
    if a.ndim != 2 or g.ndim != 2 or a.shape[0] != len(mu) or (a.shape[1] != g.shape[1]):
        raise ArchiveError('Anchor and score design dimensions differ')
    if pred.shape != (len(g),) or grid_se.shape != pred.shape or len(g) == 0:
        raise ArchiveError('Grid result dimensions differ')
    if not all((np.isfinite(x).all() for x in [mu, se, a, g, pred, grid_se])):
        raise ArchiveError('Archive contains missing or non-finite model output')
    if (se < 0).any() or (grid_se < 0).any():
        raise ArchiveError('Standard errors must be nonnegative')
    value_scale = max(float(np.max(np.abs(mu))), float(np.max(np.abs(pred))))
    se_scale = max(float(np.max(se)), float(np.max(grid_se)))
    covariance = np.diag(se ** 2)
    seen = set()
    for i, j, estimate, pair_se in differences:
        if not isinstance(i, (int, np.integer)) or not isinstance(j, (int, np.integer)) or (not 0 <= i < j < len(mu)):
            raise ArchiveError('Invalid or reversed anchor pair')
        if (i, j) in seen:
            raise ArchiveError('Duplicate anchor pair')
        if not np.isfinite([estimate, pair_se]).all() or pair_se < 0:
            raise ArchiveError('Invalid pair estimate or SE')
        if not np.isclose(estimate, mu[i] - mu[j], rtol=result_rtol, atol=result_atol * value_scale):
            raise ArchiveError('Pair estimate does not reproduce its two anchors')
        seen.add((i, j))
        covariance[i, j] = covariance[j, i] = (se[i] ** 2 + se[j] ** 2 - pair_se ** 2) / 2
    if len(seen) != len(mu) * (len(mu) - 1) // 2:
        raise ArchiveError('The archive does not contain every anchor pair')
    eig = np.linalg.eigvalsh(covariance)
    positive = se > 0
    if np.any(covariance[~positive, :] != 0) or np.any(covariance[:, ~positive] != 0):
        raise ArchiveError('A zero-variance anchor has nonzero covariance')
    if positive.any():
        correlation = covariance[np.ix_(positive, positive)] / se[positive, None] / se[None, positive]
        if np.min(np.linalg.eigvalsh(correlation)) < -1e-10 * sum(positive):
            raise ArchiveError('Recovered covariance is not positive semidefinite')
    scale = np.maximum(np.max(np.abs(a), axis=0), np.max(np.abs(g), axis=0))
    scale[scale == 0] = 1
    scaled_a = a / scale
    scaled_g = g / scale
    weights, _, rank, _ = np.linalg.lstsq(scaled_a.T, scaled_g.T, rcond=1e-12)
    weights = weights.T
    design_error = float(np.max(np.abs(weights @ scaled_a - scaled_g)))
    if design_error > design_tolerance:
        raise ArchiveError('Anchors do not span every exported score design row')
    projection = scaled_a @ np.linalg.pinv(scaled_a, rcond=1e-12)
    cov_scale = float(np.max(np.abs(covariance)))
    if not np.allclose(projection @ mu, mu, rtol=result_rtol, atol=result_atol * value_scale):
        raise ArchiveError('Anchor means violate anchor design relationships')
    if not np.allclose(projection @ covariance @ projection.T, covariance, rtol=result_rtol, atol=result_atol * cov_scale):
        raise ArchiveError('Anchor covariance violates anchor design relationships')
    recovered_mean = weights @ mu
    variance = np.einsum('ij,jk,ik->i', weights, covariance, weights)
    bounds = 64 * np.finfo(float).eps * np.einsum('ij,jk,ik->i', np.abs(weights), np.abs(covariance), np.abs(weights))
    if np.any(variance < -bounds):
        raise ArchiveError('Recovered grid variance is materially negative')
    recovered_se = np.sqrt(np.maximum(0.0, variance))
    if not np.allclose(recovered_mean, pred, rtol=result_rtol, atol=result_atol * value_scale):
        raise ArchiveError('Recovered grid predictions differ from same-fit SAS predictions')
    if not np.allclose(recovered_se, grid_se, rtol=result_rtol, atol=result_atol * se_scale):
        raise ArchiveError('Recovered grid SEs differ from same-fit SAS SEs')
    direct_contrasts = list(direct_contrasts)
    if not direct_contrasts:
        raise ArchiveError('Direct same-fit endpoint contrasts are required')
    archive = TrajectoryArchive(mu, covariance, weights, int(rank), design_error, float(np.max(np.abs(recovered_mean - pred))), float(np.max(np.abs(recovered_se - grid_se))), float(eig[0]), len(direct_contrasts))
    for coefficients, expected_mean, expected_se in direct_contrasts:
        if not np.isfinite([expected_mean, expected_se]).all() or expected_se < 0:
            raise ArchiveError('Direct contrast contains an invalid result')
        got_mean, got_se = archive.contrast(coefficients)
        if not np.isclose(got_mean, expected_mean, rtol=result_rtol, atol=result_atol * value_scale):
            raise ArchiveError('Recovered change differs from direct SAS contrast')
        if not np.isclose(got_se, expected_se, rtol=result_rtol, atol=result_atol * max(abs(got_se), abs(expected_se))):
            raise ArchiveError('Recovered change SE differs from direct SAS contrast')
    for validated in [archive.anchor_mean, archive.anchor_covariance, archive.grid_weights]:
        validated.setflags(write=False)
    return archive
