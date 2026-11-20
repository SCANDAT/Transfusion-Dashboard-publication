"""Verification of directed-decimal arithmetic at unchanged native centers."""
from __future__ import annotations
import math,numbers,re

DECIMAL_PRECISION = 80

DECIMAL_METHOD = 'DECIMAL_DIRECTED_NATIVE_CENTER_V1'

DECIMAL_PROOF_SCOPE = 'ARCHIVED_COMPUTED_M_E_AND_EXACT_NATIVE_WEIGHTS'

RESULT_FLOATS = frozenset({'denominator', 'absolute_error', 'relative_to_computed', 'relative_to_positive_ideal'})

RESULT_BOOLS = frozenset({'resolved', 'archived_center_supplied', 'center_preserved'})

RESULT_TEXT = frozenset({'method', 'scope', 'tight_replay_method', 'proof_scope'})

RESULT_KEYS = RESULT_FLOATS | RESULT_BOOLS | RESULT_TEXT | {'decimal_precision'}

RESULT_RATIOS = ('relative_to_computed', 'relative_to_positive_ideal')

_CODE = re.compile('[A-Z0-9_]{1,64}')

class DecimalReplayUnavailable(Exception):
    """Operational failure of the Decimal stage: the stage is UNCERTIFIED.

    Deliberately NOT a ValueError, so it is never converted into a scientific
    rejection by the certificate intake; the validation worker reports it as a
    non-scientific failure with a fixed code only.
    """

    def __init__(self, code):
        self.code = code if isinstance(code, str) and _CODE.fullmatch(code) else 'DECIMAL_REPLAY_FAILURE'
        super().__init__(self.code)

def verify_result(result, native_center):
    """Strict semantic verification of ONE Decimal replay dictionary at the integration boundary.

    The exact meanings are NOT re-derived here; they are those of the authoritative
    scientific arithmetic. `_finish` (roundoff_certificate_replay, the shared arithmetic implementation) maps (denominator, absolute_error) deterministically to
    relative_to_computed, relative_to_positive_ideal and resolved:
      denominator <= 0 : both ratios are positive infinity, resolved False
                         (legitimately unresolved; accepted here as such);
      denominator  > 0 : relative_to_computed is a finite outward binary64
                         bound; relative_to_positive_ideal is a finite outward
                         bound when relative_to_computed < 0.25 and positive
                         infinity otherwise (also legitimately unresolved);
                         resolved == (relative_to_positive_ideal <= 2e-8).
    DecimalScalarReplay / CachedDecimalScalarReplay additionally set the native
    center as denominator (bit pattern preserved, signed zero included), a finite
    nonnegative outward radius, tight_replay_method, decimal_precision,
    center_preserved=True and proof_scope. Therefore a dictionary is accepted iff
      1. keys are exactly RESULT_KEYS with exact Python types (float/bool/str/int);
      2. decimal_precision == 80 exactly;
      3. method/scope/tight_replay_method/proof_scope/both flags are the engine's;
      4. denominator is bit-identical to the native center the engine was asked
         to replay at (float.hex comparison distinguishes -0.0 from 0.0);
      5. absolute_error is finite and nonnegative (NaN, infinity, negative refused);
      6. relative_to_computed, relative_to_positive_ideal and resolved are
         bit-identical to _finish recomputed from (denominator, absolute_error),
         which enforces the unchanged 2e-8 rule and the exact infinity semantics
         without introducing any new numerical threshold.
    The dictionary is never altered. The native-radius-domination and native-
    resolution gates are scientific and are NOT applied here. Any failure raises
    DecimalReplayUnavailable with a fixed code: operational UNCERTIFIED.
    """
    if not isinstance(result, dict) or set(result) != RESULT_KEYS:
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_SCHEMA')
    if any((type(result[k]) is not float for k in RESULT_FLOATS)) or any((type(result[k]) is not bool for k in RESULT_BOOLS)) or any((type(result[k]) is not str for k in RESULT_TEXT)) or (type(result['decimal_precision']) is not int):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_TYPE')
    if result['decimal_precision'] != DECIMAL_PRECISION:
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_PRECISION')
    from roundoff_certificate_replay import METHOD, SCOPE, _finish
    from moment_error_certificate import Ball
    if result['method'] != METHOD or result['scope'] != SCOPE or result['tight_replay_method'] != DECIMAL_METHOD or (result['proof_scope'] != DECIMAL_PROOF_SCOPE) or (result['center_preserved'] is not True) or (result['archived_center_supplied'] is not True):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_IDENTITY')
    if isinstance(native_center, bool) or not isinstance(native_center, numbers.Real):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_TARGET_CENTER_INVALID')
    try:
        center = float(native_center)
    except (TypeError, ValueError, OverflowError):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_TARGET_CENTER_INVALID') from None
    if not math.isfinite(center):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_TARGET_CENTER_INVALID')
    if result['denominator'].hex() != center.hex():
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_CENTER_MISMATCH')
    error = result['absolute_error']
    if not math.isfinite(error) or error < 0:
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_BOUND')
    import numpy as np
    try:
        reference = _finish(Ball(np.array([[center]]), np.array([[error]])), archived=True)
    except (ValueError, ArithmeticError, FloatingPointError, TypeError):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_SEMANTICS') from None
    if any((result[k].hex() != reference[k].hex() for k in RESULT_RATIOS)):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_RATIO')
    if result['resolved'] is not reference['resolved']:
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULT_RESOLVED')
    return result

def verify_results(results, centers):
    """Complete mapping {int target key: verified dictionary}, sorted, objects unaltered.

    centers: {int target key: native center the engine was asked to replay at}.
    Missing, unknown, duplicate-by-equality or non-int keys and any per-target
    verification failure raise DecimalReplayUnavailable. Never returns a partial map.
    """
    if not isinstance(centers, dict) or any((type(k) is not int for k in centers)):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_TARGETS_INVALID')
    if not isinstance(results, dict) or any((type(k) is not int for k in results)) or set(results) != set(centers):
        raise DecimalReplayUnavailable('DECIMAL_REPLAY_RESULTS_INCOMPLETE')
    for key in sorted(centers):
        verify_result(results[key], centers[key])
    return {key: results[key] for key in sorted(centers)}
