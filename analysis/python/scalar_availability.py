"""Classify contrast-level uncertainty and apply Holm adjustment."""
from __future__ import annotations
import hashlib, json, math, re
from fractions import Fraction
STRICT = 'STRICT'
LCPU_V1 = 'LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1'
POLICIES = (STRICT, LCPU_V1)
CONFIG_KEY = 'ScalarAvailabilityPolicy'
SAS_CONTEXT_KEY = 'ScalarPolicy'
CR2_PROTOCOLS = {STRICT: 'RBC_CR2_GLS_WHITE_MODEL_V2', LCPU_V1: 'RBC_CR2_GLS_WHITE_MODEL_V2_LCPU_V1'}
UNAVAILABLE_REASON = 'MOMENT_PRECISION_UNRESOLVED'
NATIVE_UNRESOLVED_STATUS = 4
ELIGIBLE_KINDS = frozenset((1, 2))
ELIGIBLE_ROLES = ('LEVEL', 'CHANGE')
STRICT_ROLES = ('WITHIN', 'PAIRWISE')
UNCERTAINTY_FIELDS = ('StdErr', 'DF', 'tValue', 'Probt', 'Lower', 'Upper', 'Variance', 'ReferenceVariance')
CERTIFICATE_METRICS = ('Denominator', 'AbsError', 'RelativeErrorUpper', 'IdealRelativeErrorUpper', 'Resolved')
ROLE = 'scalar_unavailable'
ROLE_CHARS = ('TargetID', 'TargetRole', 'UnavailableReason')
ROLE_NUMS = ('TargetIndex', 'TargetKind', 'GridID', 'NativeContrastStatus') + CERTIFICATE_METRICS
NATIVE_RATIO_BRANCH = 0.25
CLASSES = ('RESOLVED', 'PRECISION_UNRESOLVED', 'NONPOSITIVE_CENTER', 'RATIO_NOT_BELOW_QUARTER', 'LABEL_NOT_FORCED', 'MALFORMED')
SUMMARY_KEYS = frozenset(('Policy', 'PolicyVersion', 'EligibleTargetRoles', 'StrictTargetRoles', 'UnavailableReason', 'UncertaintyUnavailableTargets', 'UncertaintyUnavailableLevels', 'UncertaintyUnavailableChanges', 'UnavailableSetSHA256', 'NativeRadiusDecimalVerified', 'DiagnosticReplayResolvesNativeUnresolved', 'NativeStatusUpgrades', 'NonsignificanceInterpretationPermitted'))
_HEX64 = re.compile('[0-9a-f]{64}')

class AvailabilityRejected(ValueError):
    """Fixed-code rejection; never carries model values."""

    def __init__(self, code):
        self.code = code if isinstance(code, str) and re.fullmatch('[A-Z0-9_]{1,64}', code) else 'SCALAR_AVAILABILITY_REJECTED'
        super().__init__(self.code)

def _finite(value):
    return isinstance(value, (int, float)) and (not isinstance(value, bool)) and math.isfinite(value)

def policy(value):
    """Normalise a TRUSTED binding value. Absent (None) means STRICT; anything else rejects."""
    if value is None:
        return STRICT
    if isinstance(value, str) and value in POLICIES:
        return value
    raise AvailabilityRejected('SCALAR_POLICY_INVALID')

def policy_from_config(config):
    """ScientificConfig -> policy. Only the versioned candidate token is ever stored there."""
    if not isinstance(config, dict):
        raise AvailabilityRejected('SCALAR_POLICY_INVALID')
    if CONFIG_KEY not in config:
        return STRICT
    if config[CONFIG_KEY] != LCPU_V1:
        raise AvailabilityRejected('SCALAR_POLICY_INVALID')
    return LCPU_V1

def cr2_protocol(value):
    """Archive identity CR2Protocol bound into every row of every role for this policy."""
    return CR2_PROTOCOLS[policy(value)]

def classify_native_certificate(row):
    """Fixed class of ONE nonzero-weight NATIVE scalar certificate row.

    RESOLVED              native claims resolution; full certification is still
                          required elsewhere (this never certifies anything).
    PRECISION_UNRESOLVED  0 < Denominator finite, 0 <= AbsError finite,
                          AbsError/Denominator <= ratio < .25 (exact rational),
                          ideal >= ratio/(1-ratio) (exact rational), ideal > 2e-8,
                          Resolved == 0, AND the unchanged rule (_finish) applied
                          to the SAME native centre and radius is unresolved.
    NONPOSITIVE_CENTER    native sub-case Denominator <= 0 (fail-closed).
    RATIO_NOT_BELOW_QUARTER  native sub-case ratio >= .25 (fail-closed).
    LABEL_NOT_FORCED      Resolved == 0 but the native centre/radius resolve
                          under the unchanged rule: an unforced downgrade label.
    MALFORMED             anything else (nonfinite, missing, inconsistent).
    No replay radius, estimate, standard error or p-value is consulted.
    """
    try:
        d = row['Denominator']
        e = row['AbsError']
        r = row['RelativeErrorUpper']
        ideal = row['IdealRelativeErrorUpper']
        resolved = row['Resolved']
    except (TypeError, KeyError):
        return 'MALFORMED'
    if not _finite(resolved) or resolved not in (0, 1):
        return 'MALFORMED'
    if resolved == 1:
        return 'RESOLVED'
    if not (_finite(d) and _finite(e)) or e < 0:
        return 'MALFORMED'
    if d <= 0:
        return 'NONPOSITIVE_CENTER'
    if not _finite(r) or r < 0 or Fraction(float(r)) < Fraction(float(e)) / Fraction(float(d)):
        return 'MALFORMED'
    if r >= NATIVE_RATIO_BRANCH:
        return 'RATIO_NOT_BELOW_QUARTER'
    if not _finite(ideal) or Fraction(float(ideal)) < Fraction(float(r)) / (1 - Fraction(float(r))):
        return 'MALFORMED'
    from roundoff_certificate_replay import LIMIT, _finish
    if not ideal > LIMIT:
        return 'MALFORMED'
    import numpy as np
    from moment_error_certificate import Ball
    try:
        with np.errstate(over='raise', divide='raise', invalid='raise', under='ignore'):
            replay = _finish(Ball(np.array([[float(d)]]), np.array([[float(e)]])), archived=True)
    except (ValueError, ArithmeticError, FloatingPointError):
        return 'MALFORMED'
    if replay['resolved']:
        return 'LABEL_NOT_FORCED'
    return 'PRECISION_UNRESOLVED'

def holm_adjusted(pvalues, family_size, tiebreak):
    """Holm step-down for a FIXED family; returns values aligned with the input order.

    Refuses any missing, NaN, infinite, boolean or out-of-range p-value and any
    change of family size. SAS MAX() and Python max() both drop a missing/NaN
    operand, which would assign Holm 0 to a missing p at rank one; this guard
    makes that impossible. Same recurrence/order as the existing validator.
    """
    if type(family_size) is not int or family_size < 0:
        raise AvailabilityRejected('HOLM_FAMILY_INVALID')
    values = list(pvalues)
    ties = list(tiebreak)
    if len(values) != family_size or len(ties) != family_size:
        raise AvailabilityRejected('HOLM_FAMILY_SIZE_CHANGED')
    for value in values:
        if not _finite(value) or not 0 <= value <= 1:
            raise AvailabilityRejected('HOLM_PVALUE_INVALID')
    if any((not _finite(t) for t in ties)) or len(set(ties)) != family_size:
        raise AvailabilityRejected('HOLM_FAMILY_INVALID')
    order = sorted(range(family_size), key=lambda i: (values[i], ties[i]))
    adjusted = [None] * family_size
    previous = 0.0
    for rank, i in enumerate(order, 1):
        previous = min(1.0, max(previous, (family_size - rank + 1) * values[i]))
        adjusted[i] = previous
    return adjusted

def unavailable_set_digest(entries):
    """Order-free SHA256 binding the exact unavailable set, reasons, native statuses
    and certificate bits (binary64 hex). Contains no estimate or uncertainty value."""
    canonical = []
    for e in entries:
        canonical.append([int(e['TargetIndex']), str(e['TargetID']), str(e['TargetRole']), int(e['TargetKind']), int(e['GridID']), int(e['NativeContrastStatus']), str(e['UnavailableReason'])] + [float(e[m]).hex() for m in CERTIFICATE_METRICS])
    canonical.sort()
    payload = json.dumps(dict(Policy=LCPU_V1, Targets=canonical), sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(payload.encode('ascii')).hexdigest()

def build_summary(entries, report):
    """Validator receipt record for LCPU_V1 (counts and digest only)."""
    levels = sum((1 for e in entries if e['TargetKind'] == 1))
    changes = sum((1 for e in entries if e['TargetKind'] == 2))
    if levels + changes != len(entries) or len({e['TargetIndex'] for e in entries}) != len(entries):
        raise AvailabilityRejected('SCALAR_UNAVAILABLE_SET_REJECTED')
    if not isinstance(report, dict):
        raise AvailabilityRejected('CERTIFICATE_REPLAY_INCOMPLETE')
    indices = {int(e['TargetIndex']) for e in entries}
    decimal = set(report.get('NativeUnresolvedDecimalVerified', ()))
    resolves = set(report.get('NativeUnresolvedReplayResolves', ()))
    if not decimal <= indices or not resolves <= indices:
        raise AvailabilityRejected('CERTIFICATE_REPLAY_INCOMPLETE')
    return validate_summary(dict(Policy=LCPU_V1, PolicyVersion=1, EligibleTargetRoles=list(ELIGIBLE_ROLES), StrictTargetRoles=list(STRICT_ROLES), UnavailableReason=UNAVAILABLE_REASON, UncertaintyUnavailableTargets=len(entries), UncertaintyUnavailableLevels=levels, UncertaintyUnavailableChanges=changes, UnavailableSetSHA256=unavailable_set_digest(entries), NativeRadiusDecimalVerified=len(decimal), DiagnosticReplayResolvesNativeUnresolved=len(resolves), NativeStatusUpgrades=0, NonsignificanceInterpretationPermitted=False))

def validate_summary(record):
    """Exact shape of a bound LCPU_V1 receipt record; raises on anything else."""
    ok = isinstance(record, dict) and set(record) == SUMMARY_KEYS and (record['Policy'] == LCPU_V1) and (type(record['PolicyVersion']) is int) and (record['PolicyVersion'] == 1) and (record['EligibleTargetRoles'] == list(ELIGIBLE_ROLES)) and (record['StrictTargetRoles'] == list(STRICT_ROLES)) and (record['UnavailableReason'] == UNAVAILABLE_REASON) and all((type(record[k]) is int and record[k] >= 0 for k in ('UncertaintyUnavailableTargets', 'UncertaintyUnavailableLevels', 'UncertaintyUnavailableChanges', 'NativeRadiusDecimalVerified', 'DiagnosticReplayResolvesNativeUnresolved'))) and (record['UncertaintyUnavailableLevels'] + record['UncertaintyUnavailableChanges'] == record['UncertaintyUnavailableTargets']) and (record['NativeRadiusDecimalVerified'] <= record['UncertaintyUnavailableTargets']) and (record['DiagnosticReplayResolvesNativeUnresolved'] <= record['UncertaintyUnavailableTargets']) and isinstance(record['UnavailableSetSHA256'], str) and bool(_HEX64.fullmatch(record['UnavailableSetSHA256'])) and (type(record['NativeStatusUpgrades']) is int) and (record['NativeStatusUpgrades'] == 0) and (record['NonsignificanceInterpretationPermitted'] is False)
    if not ok:
        raise AvailabilityRejected('SCALAR_AVAILABILITY_RECEIPT_INVALID')
    return record

def receipt_policy(validation):
    """Policy recorded in a bound validation result: no record means STRICT."""
    if not isinstance(validation, dict):
        raise AvailabilityRejected('SCALAR_AVAILABILITY_RECEIPT_INVALID')
    if 'ScalarAvailability' not in validation:
        return STRICT
    validate_summary(validation['ScalarAvailability'])
    return LCPU_V1

def require_receipt_matches(bound_policy, validation):
    """Trusted binding policy and the validated receipt must agree exactly."""
    if receipt_policy(validation) != policy(bound_policy):
        raise AvailabilityRejected('SCALAR_AVAILABILITY_BINDING_CHANGED')
    return policy(bound_policy)
