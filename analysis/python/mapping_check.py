"""Validate the association between a fitted model and its coefficient basis."""
from __future__ import annotations
from typing import Any, Callable, NamedTuple, Optional, Tuple
import numpy as np
__all__ = ['ROW_RELATIVE_TOLERANCE', 'REJECTION_CODE', 'MappingRejected', 'MappingCheckResult', 'default_need', 'intake_problem', 'row_relative_errors', 'check_scalar_weight_mapping']
ROW_RELATIVE_TOLERANCE: float = 2e-07
REJECTION_CODE: str = 'NUMERICAL_RECONSTRUCTION_REJECTED'
_INTEGER_EXACT_LIMIT: float = 2.0 ** 53
NeedFn = Callable[[bool, str], None]

class MappingRejected(Exception):
    """Raised by :func:`default_need` (and fail-closed paths) with a fixed code."""

    def __init__(self, code: str=REJECTION_CODE) -> None:
        super().__init__(code)
        self.code = code

def default_need(condition: Any, code: str=REJECTION_CODE) -> None:
    """Default ``need``: raise :class:`MappingRejected` when ``condition`` is falsy."""
    if not condition:
        raise MappingRejected(code)

class MappingCheckResult(NamedTuple):
    """Diagnostics returned when every row passes."""
    n: int
    h: int
    tolerance: float
    row_relative_error: np.ndarray
    max_relative_error: float
    worst_row: int

def _dtype_is_binary64(dtype: np.dtype) -> bool:
    return dtype.kind == 'f' and dtype.itemsize == 8

def _dtype_acceptable(dtype: np.dtype, allow_integer: bool) -> bool:
    if _dtype_is_binary64(dtype):
        return True
    if dtype.kind in 'iu':
        return allow_integer
    return False

def _scalar_leaf_ok(obj: Any, allow_integer: bool) -> bool:
    if isinstance(obj, (bool, np.bool_)):
        return False
    if isinstance(obj, (float, np.floating)):
        return True
    if isinstance(obj, (int, np.integer)):
        return allow_integer
    return False

def _leaves_ok(obj: Any, allow_integer: bool, depth: int=0) -> bool:
    """Walk nested list/tuple input; every leaf must be a permitted number."""
    if depth > 2:
        return False
    if isinstance(obj, np.ndarray):
        return _dtype_acceptable(obj.dtype, allow_integer)
    if isinstance(obj, (list, tuple)):
        return all((_leaves_ok(item, allow_integer, depth + 1) for item in obj))
    return _scalar_leaf_ok(obj, allow_integer)

def _as_binary64_matrix(value: Any, allow_integer: bool) -> Tuple[Optional[np.ndarray], str]:
    """Return ``(C-contiguous float64 2-D array, "")`` or ``(None, reason)``."""
    if value is None:
        return (None, 'input is None')
    if isinstance(value, np.ma.MaskedArray):
        return (None, 'masked arrays are not accepted')
    if isinstance(value, (str, bytes, bytearray)):
        return (None, 'text input is not numeric')
    if isinstance(value, np.ndarray):
        arr = value
    else:
        if not isinstance(value, (list, tuple)):
            return (None, f'unsupported input type {type(value).__name__}')
        if not _leaves_ok(value, allow_integer):
            return (None, 'sequence contains a non-permitted element type')
        try:
            arr = np.asarray(value)
        except (ValueError, TypeError, OverflowError):
            return (None, 'sequence is ragged or not convertible')
    if not _dtype_acceptable(arr.dtype, allow_integer):
        return (None, f'dtype {arr.dtype} is not binary64')
    if arr.ndim != 2:
        return (None, f'expected a 2-D matrix, got ndim={arr.ndim}')
    if arr.shape[0] == 0 or arr.shape[1] == 0:
        return (None, f'empty shape {arr.shape}')
    if arr.dtype.kind in 'iu':
        as_float = arr.astype(np.float64, order='C')
        if not bool(np.all(np.abs(as_float) < _INTEGER_EXACT_LIMIT)):
            return (None, 'integer magnitude too large for exact binary64 conversion')
        arr = as_float
    else:
        arr = np.ascontiguousarray(arr, dtype=np.float64)
    if not bool(np.all(np.isfinite(arr))):
        return (None, 'matrix contains NaN or infinity')
    return (arr, '')

def intake_problem(value: Any, *, allow_integer: bool=False) -> str:
    """Return ``""`` when ``value`` satisfies the input contract, else a reason."""
    _, reason = _as_binary64_matrix(value, allow_integer)
    return reason

def _scaled_row_norms(native: np.ndarray, reconstructed: np.ndarray) -> Tuple[np.ndarray, np.ndarray, bool]:
    """Return ``(diff_norm, recon_norm, zero_rows_ok)`` after common scaling.

    Both rows are multiplied by the same power of two ``2**-e`` where
    ``max(|native_i|, |reconstructed_i|) = m * 2**e`` with ``m`` in [0.5, 1).
    The inequality ``||d|| <= tol * ||r||`` is homogeneous, so a common
    positive factor leaves the exact verdict unchanged; a power of two keeps
    every normal scaled entry bit-exact.
    """
    native_max = np.max(np.abs(native), axis=1)
    recon_max = np.max(np.abs(reconstructed), axis=1)
    zero_rows_ok = bool(np.all((recon_max > 0.0) | (native_max == 0.0)))
    row_scale = np.maximum(native_max, recon_max)
    _, exponent = np.frexp(row_scale)
    shift = -exponent
    native_s = np.ldexp(native, shift[:, None])
    recon_s = np.ldexp(reconstructed, shift[:, None])
    diff = native_s - recon_s
    diff_norm = np.sqrt(np.sum(diff * diff, axis=1))
    recon_norm = np.sqrt(np.sum(recon_s * recon_s, axis=1))
    return (diff_norm, recon_norm, zero_rows_ok)

def _ratios(diff_norm: np.ndarray, recon_norm: np.ndarray) -> np.ndarray:
    ratio = np.zeros_like(diff_norm)
    positive = recon_norm > 0.0
    with np.errstate(all='ignore'):
        np.divide(diff_norm, recon_norm, out=ratio, where=positive)
    ratio[~positive & (diff_norm > 0.0)] = np.inf
    return ratio

def row_relative_errors(native: Any, reconstructed: Any, *, allow_integer: bool=False) -> np.ndarray:
    """Diagnostic per-row ratios ``||n_i - r_i|| / ||r_i||`` (``inf`` if
    ``r_i == 0`` and ``n_i != 0``; ``0`` if both are zero).

    Raises :class:`MappingRejected` on malformed input.  Does not apply the
    tolerance.  The gate itself compares norms, not these ratios, so a ratio
    printed as exactly ``2e-7`` is not proof of either verdict.
    """
    nat, _ = _as_binary64_matrix(native, allow_integer)
    default_need(nat is not None)
    rec, _ = _as_binary64_matrix(reconstructed, allow_integer)
    default_need(rec is not None)
    default_need(nat.shape == rec.shape)
    diff_norm, recon_norm, _ = _scaled_row_norms(nat, rec)
    return _ratios(diff_norm, recon_norm)

def _require(need: NeedFn, condition: Any, code: str) -> None:
    ok = bool(condition)
    need(ok, code)
    if not ok:
        raise MappingRejected(code)

def check_scalar_weight_mapping(native: Any, reconstructed: Any, need: Optional[NeedFn]=None, *, code: str=REJECTION_CODE, allow_integer: bool=False) -> MappingCheckResult:
    """Row-relative forward gate.

    Parameters
    ----------
    native, reconstructed
        Finite binary64 matrices of identical non-empty shape ``(n, h)``.
        See the module docstring for the full intake contract.
    need
        ``need(condition, code)``; must raise when ``condition`` is False.
        Defaults to :func:`default_need`, which raises :class:`MappingRejected`.
    code
        Rejection code passed to ``need`` for every check.
    allow_integer
        Accept integer dtypes with magnitudes at most ``2**53 - 1``.

    Returns
    -------
    MappingCheckResult
        Only when every row satisfies
        ``||native_i - reconstructed_i||_2 <= 2e-7 * ||reconstructed_i||_2``.
    """
    if need is None:
        need = default_need
    if not callable(need):
        raise TypeError('need must be callable as need(condition, code)')
    nat, _ = _as_binary64_matrix(native, allow_integer)
    _require(need, nat is not None, code)
    rec, _ = _as_binary64_matrix(reconstructed, allow_integer)
    _require(need, rec is not None, code)
    _require(need, nat.shape == rec.shape, code)
    diff_norm, recon_norm, zero_rows_ok = _scaled_row_norms(nat, rec)
    _require(need, zero_rows_ok, code)
    _require(need, np.all(np.isfinite(diff_norm)) and np.all(np.isfinite(recon_norm)), code)
    budget = ROW_RELATIVE_TOLERANCE * recon_norm
    _require(need, np.all(diff_norm <= budget), code)
    ratio = _ratios(diff_norm, recon_norm)
    worst = int(np.argmax(ratio))
    n, h = nat.shape
    return MappingCheckResult(n=int(n), h=int(h), tolerance=ROW_RELATIVE_TOLERANCE, row_relative_error=ratio, max_relative_error=float(ratio[worst]), worst_row=worst)
