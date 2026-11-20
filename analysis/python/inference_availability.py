"""Represent planned contrasts for fits with unavailable uncertainty estimates."""
from __future__ import annotations
import hashlib, json, re
STRICT = 'STRICT'
SPCU_V1 = 'SINGLE_PERSON_CATEGORY_CR2_UNAVAILABLE_V1'
POLICIES = (STRICT, SPCU_V1)
CONFIG_KEY = 'StructuralInferencePolicy'
SAS_CONTEXT_KEY = 'StructuralPolicy'
RECORD_KEY = 'InferenceAvailability'
RECEIPT_STATUS = 'EXPECTED_INFERENCE_UNAVAILABLE_VALIDATED'
STAGE_STATUS = {'WORKING_MODEL': 'VALIDATED', 'CR2': RECEIPT_STATUS}
INTEGRATION_STATUS = 'EXPECTED_INFERENCE_UNAVAILABLE'
KERNEL_REASON = 'PLANNED_TARGET_NOT_LOO_ESTIMABLE'
SUPPORT_REASON = 'ACTIVE_CATEGORY_SINGLE_PERSON'
UNAVAILABLE_SCOPE = 'WHOLE_PLANNED_CR2_FAMILY'
TARGET_CLAIM = 'AT_LEAST_ONE_PLANNED_TARGET_NOT_LOO_ESTIMABLE'
STATISTICS_POLICY = 'NO_CR2_STATISTICS_EXPORTED'
CERTIFICATE_KIND = 'WITHIN_TARGET_EXCLUSIVE_COLUMN'
SUPPORT_CERTIFICATE = 'EXCLUSIVE_CATEGORY_SUPPORT_V1'
INFERENCE_STATUS = 'CR2_INFERENCE_UNAVAILABLE'
PLANNED_COVARIANCE = 'GLS_WHITENED_CR2'
ARCHIVE_PROTOCOL = 'RBC_CR2_INFERENCE_UNAVAILABLE_ARCHIVE_V1'
VALIDATION_PROTOCOL = 'RBC_CR2_INFERENCE_UNAVAILABLE_VALIDATION_V1'
FILE_INFIX = '_iu_'
NUMERIC_FORMAT = 'HEX16_IEEE754'
SCOPE_PAIRS = {'synthetic': 'SYNTHETIC_DATA_ONLY', 'development_sample': 'LOCAL_SAMPLE_MODEL_INFERENCE', 'full_cohort': 'FULL_COHORT_MODEL_INFERENCE'}
CONTEXT_CHARS = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind WorkingDFMethod WorkingInferenceStatus Scope PlannedCovarianceMethod InferenceStatus InferencePolicy InferenceArchiveID SupportCertificate'.split())
CONTEXT_NUMS = ('BindingVersion', 'WorkingBindingVersion')
CONTEXT = CONTEXT_CHARS + CONTEXT_NUMS
COPIED_WORKING = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind'.split())
ROLE_SCHEMAS = {'identity': ((), ()), 'status': (('IntegrationStatus', 'ReasonCode', 'SupportReason', 'UnavailableScope', 'TargetClaim', 'StatisticsPolicy'), ('PlannedCategories', 'ActiveCategories', 'PlannedScalarTargets', 'PlannedJointTests', 'SinglePersonCategories', 'CertificateColumns', 'ParameterCount', 'ClusterCount')), 'cat_availability': (('AvailabilityReason',), ('CategoryCode', 'CategoryIndex', 'Available')), 'contrast_plan': (('ContrastID', 'ContrastType', 'ExclusionReason', 'FamilyID'), ('CategoryCodeA', 'CategoryCodeB', 'CategoryIndexA', 'CategoryIndexB', 'Planned', 'Active', 'BeforeMinute', 'AfterMinute')), 'family_plan': (('FamilyID', 'FamilyRole', 'FactorName', 'Model', 'VitalCode', 'PAdjustment', 'CIAdjustment', 'FreezeStage'), ('PlannedCategories', 'AvailableCategories', 'PlannedPairs', 'ActivePairs', 'PlanVersion')), 'support_certificate': (('CertificateKind',), ('CategoryCode', 'CategoryIndex', 'ColumnIndex', 'WithinCoefficientNonzero', 'CategorySpecificInScoring', 'SupportPersonsCappedAt2'))}
ROLES = tuple(ROLE_SCHEMAS)
MANIFEST_CHARS = ('Protocol', 'Role', 'FileName', 'NumericFormat', 'TextEncoding', 'ExportStatus')
MANIFEST_NUMS = ('RowCount', 'ColumnCount')
STATISTIC_FIELDS = frozenset((x.casefold() for x in 'Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance PValue PValue_Holm Rank FValue ProbF Wald Q Nu DF1 DF2 MomentDenominator Predicted Delta PointEstimate'.split()))
RECORD_KEYS = frozenset(('Policy', 'PolicyVersion', 'IntegrationStatus', 'ReasonCode', 'SupportReason', 'UnavailableScope', 'TargetClaim', 'StatisticsPolicy', 'PlannedCategories', 'ActiveCategories', 'PlannedScalarTargets', 'PlannedJointTests', 'SinglePersonCategoryCodes', 'CertificateColumns', 'SupportCertificateSHA256', 'ModelBasedSubstitutionPermitted', 'NonsignificanceInterpretationPermitted', 'CategoryCollapsingApplied', 'FamilyShrinkageApplied'))
_HEX64 = re.compile('[0-9a-f]{64}')

class AvailabilityRejected(ValueError):
    """Fixed-code rejection; never carries model values."""

    def __init__(self, code):
        self.code = code if isinstance(code, str) and re.fullmatch('[A-Z0-9_]{1,64}', code) else 'INFERENCE_AVAILABILITY_REJECTED'
        super().__init__(self.code)

def _schema_self_check():
    for role, (chars, nums) in ROLE_SCHEMAS.items():
        fields = CONTEXT + chars + nums
        if len({f.casefold() for f in fields}) != len(fields) or any((f.casefold() in STATISTIC_FIELDS for f in fields)):
            raise AvailabilityRejected('INFERENCE_SCHEMA_INVALID')
_schema_self_check()

def policy(value):
    """Normalise a TRUSTED binding value. Absent (None) means STRICT; anything else rejects."""
    if value is None:
        return STRICT
    if isinstance(value, str) and value in POLICIES:
        return value
    raise AvailabilityRejected('STRUCTURAL_POLICY_INVALID')

def policy_from_config(config):
    """ScientificConfig -> policy. Only the versioned candidate token is ever stored there."""
    if not isinstance(config, dict):
        raise AvailabilityRejected('STRUCTURAL_POLICY_INVALID')
    if CONFIG_KEY not in config:
        return STRICT
    if config[CONFIG_KEY] != SPCU_V1:
        raise AvailabilityRejected('STRUCTURAL_POLICY_INVALID')
    return SPCU_V1

def file_name(prefix, role):
    return prefix + FILE_INFIX + role + '.csv'

def file_names(prefix):
    return {file_name(prefix, role) for role in (*ROLES, 'archive_manifest')}

def role_chars(role):
    """Character fields of one archive role (typed lookup for decimal conversion)."""
    if role == 'archive_manifest':
        return MANIFEST_CHARS
    if role not in ROLE_SCHEMAS:
        raise ValueError('ROLE_NOT_ALLOWED')
    return ROLE_SCHEMAS[role][0]

def planned_scalar_targets(k):
    return 2 * 1441 * k + k + k * (k - 1) // 2

def planned_joint_tests(k):
    return 2 if k > 1 else 0

def certificate_digest(rows):
    """Order-free SHA256 of the exact certificate (category code, index, design column)."""
    canonical = sorted(([int(code), int(index), int(column)] for code, index, column in rows))
    payload = json.dumps(dict(Policy=SPCU_V1, Certificate=canonical), sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(payload.encode('ascii')).hexdigest()

def build_record(*, planned, active, single_codes, certificate_rows):
    """Receipt record (counts, plan category codes and one digest; no model value)."""
    codes = sorted((int(c) for c in single_codes))
    rows = list(certificate_rows)
    if not codes or len(set(codes)) != len(codes) or {int(r[0]) for r in rows} != set(codes):
        raise AvailabilityRejected('INFERENCE_RECORD_INVALID')
    return validate_record(dict(Policy=SPCU_V1, PolicyVersion=1, IntegrationStatus=INTEGRATION_STATUS, ReasonCode=KERNEL_REASON, SupportReason=SUPPORT_REASON, UnavailableScope=UNAVAILABLE_SCOPE, TargetClaim=TARGET_CLAIM, StatisticsPolicy=STATISTICS_POLICY, PlannedCategories=int(planned), ActiveCategories=int(active), PlannedScalarTargets=planned_scalar_targets(int(active)), PlannedJointTests=planned_joint_tests(int(active)), SinglePersonCategoryCodes=codes, CertificateColumns=len(rows), SupportCertificateSHA256=certificate_digest(rows), ModelBasedSubstitutionPermitted=False, NonsignificanceInterpretationPermitted=False, CategoryCollapsingApplied=False, FamilyShrinkageApplied=False))

def validate_record(record):
    """Exact shape of a bound SPCU_V1 receipt record; raises on anything else."""

    def whole(key, low=0):
        return type(record.get(key)) is int and record[key] >= low
    ok = isinstance(record, dict) and set(record) == RECORD_KEYS and (record['Policy'] == SPCU_V1) and (type(record['PolicyVersion']) is int) and (record['PolicyVersion'] == 1) and (record['IntegrationStatus'] == INTEGRATION_STATUS) and (record['ReasonCode'] == KERNEL_REASON) and (record['SupportReason'] == SUPPORT_REASON) and (record['UnavailableScope'] == UNAVAILABLE_SCOPE) and (record['TargetClaim'] == TARGET_CLAIM) and (record['StatisticsPolicy'] == STATISTICS_POLICY) and whole('PlannedCategories', 2) and whole('ActiveCategories', 2) and whole('PlannedScalarTargets', 1) and whole('PlannedJointTests') and whole('CertificateColumns', 1)
    if ok:
        k = record['ActiveCategories']
        codes = record['SinglePersonCategoryCodes']
        ok = k <= record['PlannedCategories'] <= 7 and record['PlannedScalarTargets'] == planned_scalar_targets(k) and (record['PlannedJointTests'] == planned_joint_tests(k)) and isinstance(codes, list) and (1 <= len(codes) <= k) and all((type(c) is int and c >= 0 for c in codes)) and (codes == sorted(set(codes))) and (record['CertificateColumns'] >= len(codes)) and isinstance(record['SupportCertificateSHA256'], str) and bool(_HEX64.fullmatch(record['SupportCertificateSHA256'])) and all((record[x] is False for x in ('ModelBasedSubstitutionPermitted', 'NonsignificanceInterpretationPermitted', 'CategoryCollapsingApplied', 'FamilyShrinkageApplied')))
    if not ok:
        raise AvailabilityRejected('INFERENCE_AVAILABILITY_RECEIPT_INVALID')
    return record

def receipt_policy(validation):
    """Policy evidenced by a bound validation result: no record means STRICT."""
    if not isinstance(validation, dict):
        raise AvailabilityRejected('INFERENCE_AVAILABILITY_RECEIPT_INVALID')
    if RECORD_KEY not in validation:
        if validation.get('Status') == RECEIPT_STATUS:
            raise AvailabilityRejected('INFERENCE_AVAILABILITY_RECEIPT_INVALID')
        return STRICT
    if validation.get('Status') != RECEIPT_STATUS or validation.get('StageStatus') != STAGE_STATUS:
        raise AvailabilityRejected('INFERENCE_AVAILABILITY_RECEIPT_INVALID')
    validate_record(validation[RECORD_KEY])
    return SPCU_V1
GUARD_KEY = 'StructuralSupportGuard'
GUARD_PASS = 'PASS_NO_ACTIVE_SINGLE_PERSON_CATEGORY'
CONTRADICTION = 'SINGLE_PERSON_CATEGORY_CR2_PASS_CONTRADICTION'
CR2_SUCCESS_STATUS = 'ARCHIVE_VALIDATED'

def single_person_codes(value):
    """Exact evidence: sorted, duplicate-free list of non-negative int category codes (may be empty)."""
    if not isinstance(value, list) or any((type(c) is not int or c < 0 for c in value)) or value != sorted(set(value)):
        raise AvailabilityRejected('SINGLE_PERSON_EVIDENCE_REQUIRED')
    return list(value)

def supported_guard(codes):
    """Authoritative decision for a CR2 success under SPCU_V1, on independently derived evidence:
    the validated ACTIVE category codes with N_Patients == 1. Empty -> fixed PASS attestation;
    any code -> contradiction. Never consults the receipt or the CR2 archive."""
    if single_person_codes(codes):
        raise AvailabilityRejected(CONTRADICTION)
    return GUARD_PASS

def claims_cr2_success(validation):
    """A receipt that claims a successful (validated) CR2 stage."""
    stages = validation.get('StageStatus') if isinstance(validation, dict) else None
    return isinstance(validation, dict) and validation.get('Status') == CR2_SUCCESS_STATUS and isinstance(stages, dict) and (stages.get('CR2') == 'VALIDATED')

def guard_marker(validation):
    """Policy-free shape check. Returns GUARD_PASS or None (absent). An unknown value, a
    non-dict Checks, or a marker on any receipt that does not claim CR2 success rejects."""
    if not isinstance(validation, dict):
        raise AvailabilityRejected('INFERENCE_AVAILABILITY_RECEIPT_INVALID')
    if 'Checks' not in validation:
        return None
    checks = validation['Checks']
    if not isinstance(checks, dict):
        raise AvailabilityRejected('STRUCTURAL_SUPPORT_GUARD_INVALID')
    if GUARD_KEY not in checks:
        return None
    if type(checks[GUARD_KEY]) is not str or checks[GUARD_KEY] != GUARD_PASS:
        raise AvailabilityRejected('STRUCTURAL_SUPPORT_GUARD_INVALID')
    if not claims_cr2_success(validation):
        raise AvailabilityRejected('STRUCTURAL_SUPPORT_GUARD_UNEXPECTED')
    return GUARD_PASS

def require_receipt_matches(bound_policy, validation):
    """An inference-unavailable receipt is acceptable only under the SAME bound policy.
    Under a bound SPCU_V1 policy a CR2-success receipt must carry exactly the fixed
    StructuralSupportGuard attestation; under STRICT (unchanged) no receipt may carry it, and
    inference-unavailable, pre-fit unavailable and report receipts never carry it."""
    bound = policy(bound_policy)
    found = receipt_policy(validation)
    if found == SPCU_V1 and bound != SPCU_V1:
        raise AvailabilityRejected('INFERENCE_AVAILABILITY_BINDING_CHANGED')
    marker = guard_marker(validation)
    if bound == SPCU_V1 and claims_cr2_success(validation):
        if marker != GUARD_PASS:
            raise AvailabilityRejected('STRUCTURAL_SUPPORT_GUARD_REQUIRED')
    elif marker is not None:
        raise AvailabilityRejected('STRUCTURAL_SUPPORT_GUARD_UNEXPECTED')
    return bound
