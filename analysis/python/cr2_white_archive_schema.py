"""File roles and columns for whitened CR2 model summaries."""
from __future__ import annotations
PROTOCOL = 'RBC_CR2_GLS_WHITE_ARCHIVE_V2'
CONTEXT_CHARS = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId DFMethod JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind InferenceStatus WorkingDFMethod WorkingInferenceStatus Scope CovarianceMethod ScalarDFMethod JointDFMethod WorkingTarget CR2Protocol CR2ArchiveID CalibrationDomain StructuralCertificate'.split())
CONTEXT_NUMS = ('BindingVersion', 'WorkingBindingVersion', 'TargetCalibrationVerified', 'AllCoefficientsCalibrated')
CONTEXT = CONTEXT_CHARS + CONTEXT_NUMS
TARGET_CHARS = tuple('TargetID TargetRole NumericStatus PAdjustment CIAdjustment FamilyID'.split())
TARGET_NUMS = tuple('TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB ContrastStatus Estimate StdErr DF tValue Probt Lower Upper Variance ReferenceVariance BaselineMinute EndpointMinute'.split())

def schemas(p: int, rank: int, h: int, k: int, *, scalar_policy=None) -> dict:
    """scalar_policy None/STRICT: the historical exact role set (unchanged).
    LEVEL_CHANGE_PRECISION_UNAVAILABLE_V1 adds exactly one role, scalar_unavailable,
    whose row count is the declared unavailable-set size (count None here; the
    validator binds it to the manifest and re-derives the set independently)."""
    if any((type(x) is not int or x < 1 for x in (p, rank, h, k))) or not h <= rank <= p or p > 500 or (k > 7):
        raise ValueError('CR2_SCHEMA_DIMENSIONS_INVALID')
    d = h * (h + 1) // 2
    if 8 * (4 * d * (rank * (rank + 1) // 2) + 6 * d * d) > 512 * 2 ** 20:
        raise ValueError('CR2_SCHEMA_SIZE_LIMIT')
    dr = rank * (rank + 1) // 2
    if 8 * (12 * d * dr + 32 * d * d) + 64 * 2 ** 20 > 2048 * 2 ** 20:
        raise ValueError('CR2_CERTIFICATE_SIZE_LIMIT')
    x = tuple((f'RBCX{i}' for i in range(1, p + 1)))
    col = lambda n: tuple((f'COL{i}' for i in range(1, n + 1)))
    pairs = k * (k - 1) // 2
    targets = 2 * 1441 * k + k + pairs
    s = {'identity': ((), (), 1), 'status': (('IntegrationStatus', 'ReasonCode'), (), 1), 'working_target': ((), ('Tau2', 'Sigma2', 'Alpha', 'ComponentCount', 'RIComponents', 'ResidualComponents'), 1), 'levels': (TARGET_CHARS, TARGET_NUMS, 1441 * k), 'changes': (TARGET_CHARS, TARGET_NUMS, 1441 * k), 'within': (TARGET_CHARS, TARGET_NUMS, k), 'pairwise': (TARGET_CHARS, TARGET_NUMS + ('Rank', 'PValue', 'PValue_Holm'), pairs), 'joint': (('TestRole', 'NumericStatus'), tuple('TestIndex JointStatus Q Nu DF1 DF2 Wald FValue ProbF MomentDenominator'.split()), 2), 'cat_availability': (('AvailabilityReason',), ('CategoryCode', 'CategoryIndex', 'Available'), None), 'contrast_plan': (tuple('ContrastID ContrastType ExclusionReason FamilyID'.split()), tuple('CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active BeforeMinute AfterMinute'.split()), None), 'family_plan': (tuple('FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage'.split()), tuple('PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion'.split()), 1), 'si_covariance': ((), ('Row', 'Col', 'Value'), p * p), 'si_basis': ((), ('Parameter', 'ActiveColumn', 'Value'), p * rank), 'si_bread': ((), ('Row', 'Col', 'Value'), rank * rank), 'si_moment': ((), col(d), d), 'si_spanbasis': ((), col(p), h), 'si_spanrobust': ((), col(h), h), 'si_solution': ((), ('Parameter', 'Estimate'), p), 'si_context': (('StatisticKind',), tuple('Tau2 Sigma2 Alpha DesignRank ParameterCount ClusterCount SpanDimension MomentDimension RoundoffEnvelope CertifiedClusters MaxCertifiedNullity'.split()), 1), 'target_keys': ((), tuple('TargetIndex TargetKind GridID CategoryIndexA CategoryIndexB TimeFromTransfusion CategoryCodeA CategoryCodeB'.split()), targets), 'target_design': ((), ('TargetIndex',) + x, targets)}
    if k > 1:
        s['joint_design'] = ((), ('TestIndex', 'ConstraintIndex', 'CategoryIndex', 'AnchorIndex') + x, 7 * (k - 1))
    from certificate_archive_schema import CERTIFICATE_CONTEXT_CHARS, CERTIFICATE_CONTEXT_NUMS, METRICS, INTERVALS
    s.update({'si_moment_error': ((), col(d), d), 'si_scalar_weights': ((), ('TargetIndex',) + col(h), targets), 'si_scalar_certificate': ((), ('TargetIndex',) + METRICS, targets), 'joint_weights': ((), ('TestIndex', 'ConstraintIndex') + col(h), 7 * (k - 1)), 'joint_certificate': ((), ('TestIndex',) + METRICS + INTERVALS, 2 if k > 1 else 0), 'certificate_context': (CERTIFICATE_CONTEXT_CHARS, CERTIFICATE_CONTEXT_NUMS, 1)})
    from scalar_availability import policy as _scalar_policy, LCPU_V1, ROLE, ROLE_CHARS, ROLE_NUMS
    if _scalar_policy(scalar_policy) == LCPU_V1:
        s[ROLE] = (ROLE_CHARS, ROLE_NUMS, None)
    for chars, nums, _ in s.values():
        fields = CONTEXT + chars + nums
        if len({f.casefold() for f in fields}) != len(fields):
            raise ValueError('CR2_SCHEMA_DUPLICATE_FIELD')
    return s

def white_role_sets(scalar_policy=None):
    """Exact permitted CR2 exchange inventories (role names incl. archive_manifest)
    for ONE bound policy: with and without joint_design. A strict receipt can never
    carry scalar_unavailable; an LCPU_V1 receipt must carry it."""
    full = set(schemas(1, 1, 1, 2, scalar_policy=scalar_policy)) | {'archive_manifest'}
    return [full, full - {'joint_design'}]

def role_chars(role):
    """Character fields of one CR2 role across every policy (typed lookup only)."""
    from scalar_availability import LCPU_V1
    ch = {key: value[0] for key, value in schemas(1, 1, 1, 2, scalar_policy=LCPU_V1).items()}
    ch['archive_manifest'] = tuple('Protocol Role FileName NumericFormat TextEncoding ExportStatus'.split())
    if role not in ch:
        raise ValueError('ROLE_NOT_ALLOWED')
    return ch[role]

def svec_pairs(h):
    return [(row, column) for row in range(h) for column in range(row, h)]
