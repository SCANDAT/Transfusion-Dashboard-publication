import { FACTORS, MODELS, OUTCOMES, POPULATIONS, type ArtifactReference, type DatasetKind, type FitKey, type ValidatedRelease } from './release'
import { type ResultTable, type TableCell, type TableRow } from './tables'

export const SUPPLEMENT_SCHEMA = 'transfusion-dashboard/supplements-v1' as const
export const REPORT_TABLE_SCHEMA = 'transfusion-dashboard/report-table-v1' as const
export const PROFILE_TABLE_SCHEMA = 'transfusion-dashboard/profile-table-v1' as const
export const METHODS_SCHEMA = 'transfusion-dashboard/methods-v1' as const
export const METHODS_SCHEMA_V2 = 'transfusion-dashboard/methods-v2' as const

/** Original field names and types; this schema contains no result values. */
export const REPORT_CONTEXT_FIELDS = ["RunId", "AnalysisSpecId", "CohortMode", "InputSnapshotId", "CodeHash", "ConfigHash", "ReportRunId", "ReportCodeHash", "ReportConfigHash", "ExportId", "ExportCodeHash", "Bundle", "PopulationId", "DisclosureStatus"] as const
export const REPORT_SCHEMAS = {
  flow_metrics: {characterFields: ["FlowProtocol", "MetricID", "Stage", "CountingUnit", "Overlap", "DenominatorID", "DataScope"], numericFields: ["Count"]},
  flow_checks: {characterFields: ["FlowProtocol", "Check", "Status", "DataScope"], numericFields: []},
  factor_observed_data_summary: {"characterFields": ["VitalCode", "Outcome", "Factor", "CategoryLabel", "Abbreviation", "FactorName", "FactorCategory", "InferenceMethod", "DenominatorDefinition", "Status", "InferenceStatus", "Pre_InferenceStatus", "Post_InferenceStatus", "InferenceApprovalStatus"], "numericFields": ["OutcomeOrder", "CategoryCode", "NEligibleEvents", "NEligiblePatients", "NPreAvailableEvents", "NPostAvailableEvents", "NDiff", "NPairedPatients", "NPreOnlyEvents", "NPostOnlyEvents", "NNeitherAvailableEvents", "NPreWindowRecords", "NPostWindowRecords", "NPairedPreValues", "NPairedPostValues", "Pre_Mean", "Pre_SD", "Post_Mean", "Post_SD", "Diff_Mean", "Diff_SD", "WindowHalfWidthMinutes", "Diff_SE", "Diff_LCL", "Diff_UCL", "DF", "PValue", "Pre_SE", "Pre_DF", "Pre_LCL", "Pre_UCL", "Post_SE", "Post_DF", "Post_LCL", "Post_UCL", "FitPersons", "FitEvents", "FitCategories", "ScoreIdentityNorm"]},
  followup_counts: {"characterFields": ["FollowupStatus", "CoverageScope", "CoverageEndBoundary", "FollowupDefinition"], "numericFields": ["NEvents", "NPersons"]},
  observed_covariance: {"characterFields": ["VitalCode", "Outcome", "Factor", "InferenceStatus", "InferenceApprovalStatus"], "numericFields": ["CategoryA", "CategoryB", "Covariance", "DF", "FitPersons", "FitEvents", "FitCategories"]},
  observed_data_summary: {"characterFields": ["VitalCode", "Outcome", "Factor", "CategoryLabel", "Abbreviation", "FactorName", "FactorCategory", "InferenceMethod", "DenominatorDefinition", "Status", "InferenceStatus", "Pre_InferenceStatus", "Post_InferenceStatus", "InferenceApprovalStatus"], "numericFields": ["OutcomeOrder", "CategoryCode", "NEligibleEvents", "NEligiblePatients", "NPreAvailableEvents", "NPostAvailableEvents", "NDiff", "NPairedPatients", "NPreOnlyEvents", "NPostOnlyEvents", "NNeitherAvailableEvents", "NPreWindowRecords", "NPostWindowRecords", "NPairedPreValues", "NPairedPostValues", "Pre_Mean", "Pre_SD", "Post_Mean", "Post_SD", "Diff_Mean", "Diff_SD", "WindowHalfWidthMinutes", "Diff_SE", "Diff_LCL", "Diff_UCL", "DF", "PValue", "Pre_SE", "Pre_DF", "Pre_LCL", "Pre_UCL", "Post_SE", "Post_DF", "Post_LCL", "Post_UCL", "FitPersons", "FitEvents", "FitCategories", "ScoreIdentityNorm"]},
  observed_exclusions: {"characterFields": ["Factor", "ReasonCode", "InferenceApprovalStatus"], "numericFields": ["NExcludedEvents", "NExcludedPatients"]},
  observed_joint_covariance: {"characterFields": ["VitalCode", "Outcome", "Factor", "MetricA", "MetricB", "InferenceStatus", "InferenceApprovalStatus"], "numericFields": ["CategoryA", "CategoryB", "Covariance", "DF", "FitPersons", "FitEvents", "FitCategories"]},
  observed_manifest: {"characterFields": ["WindowPolicy", "Weighting", "PairingDefinition", "ValueScale", "InferenceApprovalStatus", "AnalysisRole", "ClusterUnit", "VarianceAdjustment", "IntervalDistribution", "JointCovarianceSource", "ResponseCentering"], "numericFields": ["PreLowerMinutes", "PreUpperMinutes", "PostLowerMinutes", "PostUpperMinutes", "ConfidenceLevel"]},
  observed_pairwise: {"characterFields": ["VitalCode", "Outcome", "Factor", "InferenceStatus", "InferenceMethod", "InferenceApprovalStatus"], "numericFields": ["OutcomeOrder", "CategoryA", "CategoryB", "NEventsA", "NEventsB", "NPersonsA", "NPersonsB", "Estimate", "StdErr", "DF", "Lower", "Upper", "PValue", "FitPersons", "FitEvents", "FitCategories"]},
  pipeline_identity: {"characterFields": ["CoverageStatus", "UnitStatus", "ExecutionStatus", "AgeBandDefinition", "SourceYearBoundsMeaning"], "numericFields": ["SourceExtractFirstYear", "SourceExtractLastYear"]},
  population_counts: {"characterFields": ["ReportedPopulationId", "PopulationStatus", "CoverageScope", "CoverageEndBoundary", "FollowupDefinition"], "numericFields": ["NEvents", "NPersons"]},
  prepare_manifest: {"characterFields": ["MappingEvidence", "ModelGroupingEvidence", "AdmissionPolicy", "ConcurrentPolicy", "UnitKeyDefinition", "PriorUnitDefinition", "IndexHistoryDefinition", "LedgerCoverage", "MedicationEncoding", "NativeOutcomeUnits", "ScientificFreeze", "DonationDateUnit", "RuleApproval", "MeasurementReconciliation", "MedicationReconciliation", "MedicationNormalizationRule", "AdmissionTimeDateStyle", "DataScope"], "numericFields": ["NormalizationMeasurementCount", "NormalizationFieldCount", "Normalized_Crystalloid_1", "Normalized_Crystalloid_24", "Normalized_Pressors_1", "Normalized_Pressors_24", "Normalized_Sedatives_1", "Normalized_Sedatives_24", "NormalizationRelativeBound", "OriginalDistinctPayloadRows"]},
  prepare_status: {"characterFields": ["Predicate", "Status", "DataScope"], "numericFields": []},
  qa_covariate_missing: {"characterFields": ["VitalCode", "Outcome", "Variable", "MissingDefinition", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NRows", "NMissing", "NNonmissing"]},
  qa_duplicate_records: {"characterFields": ["VitalCode", "Outcome", "DuplicateKeyDefinition", "ActionTaken", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NDuplicateGroups", "NRowsInDuplicateGroups", "NExtraDuplicateRows", "NMissingDuplicateKeyRows"]},
  qa_outcome_counts: {"characterFields": ["VitalCode", "Outcome", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NRows", "NPatients", "NEvents", "NPatientsWithValue", "NEventsWithValue", "NMissingValue", "NMissingPersonKey", "NMissingEventKey", "NMissingDatetime", "NMissingTransDt", "NNegativeValueFlag", "NOxygenAbove100Flag", "NNegativeICUTimeFlag", "NNegativeRBCCountFlag", "NNonintegerRBCCountFlag", "NNegativeCrystalloid1Flag", "NNegativeCrystalloid24Flag", "NNegativePressors1Flag", "NNegativePressors24Flag", "NNegativeSedatives1Flag", "NNegativeSedatives24Flag", "NRowsMissingBaseCovariate", "NRowsMissingFullCovariate"]},
  qa_processing_status: {"characterFields": ["Field", "Status", "Interpretation", "ActionTaken", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": []},
  qa_record_intervals: {"characterFields": ["VitalCode", "Outcome", "CoverageStatus", "DefinitionId", "SourceGroup", "GroupingDefinition", "QuantilePopulation", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NUniqueMeasurements", "NUniqueTimestamps", "NIntervals", "NNonpositiveIntervals", "NSeriesStarts", "NMissingDatetime", "NTimestampTieGroups", "NRecordsAtTiedTimestamps", "IntervalP5Seconds", "Q1IntervalSeconds", "MedianIntervalSeconds", "Q3IntervalSeconds", "IntervalP95Seconds"]},
  qa_source_value_quantiles: {"characterFields": ["VitalCode", "Outcome", "CoverageStatus", "QuantileMethod", "ValuePopulation", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NValues", "ValueP5", "ValueP25", "ValueP50", "ValueP75", "ValueP95"]},
  qa_value_quantiles: {"characterFields": ["VitalCode", "Outcome", "QuantileMethod", "ValuePopulation", "SourcePopulationId", "AnalysisPopulationId"], "numericFields": ["OutcomeOrder", "NValues", "ValueP5", "ValueP25", "ValueP50", "ValueP75", "ValueP95"]},
  rdd_anchor_audit: {"characterFields": ["DenominatorDefinition", "DenominatorScope"], "numericFields": ["NPersons", "PersonsWithChangingAge", "PersonsWithChangingSex", "PersonsWithEquivalentFirstTies", "Denominator"]},
  rdd_cohort_counts: {"characterFields": ["CountingUnit", "CountDefinition"], "numericFields": ["Count"]},
  rdd_manifest: {"characterFields": ["AnchorPolicy", "TiePolicy", "UnitScope", "AgeRangePolicy", "SAPSOption", "DescriptorStatus"], "numericFields": []},
  rdd_patient_age: {"characterFields": ["DenominatorDefinition", "DenominatorScope"], "numericFields": ["N_Age", "N_Missing_Age", "Mean_Age", "SD_Age", "Median_Age", "Q1_Age", "Q3_Age", "Min_Age", "Max_Age", "NPersons", "Denominator"]},
  rdd_patient_age_groups: {"characterFields": ["BandCode", "BandLabel", "DenominatorDefinition", "DenominatorScope"], "numericFields": ["BandOrder", "Count", "Denominator", "Percent"]},
  rdd_patient_saps: {"characterFields": ["Status", "DenominatorDefinition", "DenominatorScope"], "numericFields": ["NAvailable", "Mean", "SD", "Median", "Q1", "Q3", "NPersons", "NMissing", "NInvalid", "NNotRequested", "Denominator"]},
  rdd_patient_sex: {"characterFields": ["Patient_Sex", "DenominatorDefinition", "DenominatorScope"], "numericFields": ["No_of_Patients", "Denominator", "Percent"]},
  rdd_patient_ward: {"characterFields": ["WardCode", "Status", "DenominatorDefinition", "DenominatorScope"], "numericFields": ["No_of_Patients", "Denominator"]},
  rdd_unit_categories: {"characterFields": ["Factor", "CategoryCode", "CategoryLabel", "Status", "DenominatorDefinition"], "numericFields": ["Eligible", "No_of_Transfused_Units", "NTotalUnits", "NEligibleUnits", "NValid", "NMissing", "NInvalid", "NExcluded", "Percent"]},
  rdd_units_per_person: {"characterFields": ["UnitScope", "CountDefinition", "DenominatorDefinition", "DenominatorScope"], "numericFields": ["Linked_Index_Units", "No_of_Patients", "Denominator", "Relative_Frequency"]},
  report_identity: {"characterFields": ["ReportStatus"], "numericFields": []},
  report_status: {"characterFields": ["Status"], "numericFields": []},
  report_unavailable: {"characterFields": ["Item", "AvailabilityStatus", "ReasonCode"], "numericFields": []},
  source_exclusions: {"characterFields": ["Stage", "CountingUnit", "ReasonCode", "DataScope"], "numericFields": ["Count"]},
  source_flow: {"characterFields": ["Stage", "CountingUnit", "DataScope"], "numericFields": ["Count"]},
} as const
export const PREPARATION_REPORT_ROLES = ["flow_metrics", "flow_checks", "followup_counts", "pipeline_identity", "population_counts", "prepare_manifest", "prepare_status", "source_exclusions", "source_flow"] as const
export const POPULATION_REPORT_ROLES = ["factor_observed_data_summary", "observed_covariance", "observed_data_summary", "observed_exclusions", "observed_joint_covariance", "observed_manifest", "observed_pairwise", "pipeline_identity", "population_counts", "qa_covariate_missing", "qa_duplicate_records", "qa_outcome_counts", "qa_processing_status", "qa_record_intervals", "qa_source_value_quantiles", "qa_value_quantiles", "rdd_anchor_audit", "rdd_cohort_counts", "rdd_manifest", "rdd_patient_age", "rdd_patient_age_groups", "rdd_patient_saps", "rdd_patient_sex", "rdd_patient_ward", "rdd_unit_categories", "rdd_units_per_person", "report_identity", "report_status", "report_unavailable"] as const
export const PROFILE_CONTEXT_FIELDS = ["RunId", "AnalysisSpecId", "CohortMode", "PopulationId", "FitId", "InputSnapshotId", "CodeHash", "ConfigHash", "DesignId", "ProfileId", "JobID", "ProfileIdentityKind", "SelectedAttemptId", "Model", "FactorName", "VitalCode", "ReferenceProfileStatus", "ConstructionId", "SourceProfileSHA256"] as const
export const PROFILE_CLASS_FIELDS = ["PatientSex", "WardName"] as const
export const PROFILE_BASE_NUMERIC_FIELDS = ["PatientAge", "ICU_time", "RBC_Count"] as const
export const PROFILE_FULL_NUMERIC_FIELDS = ["Crystalloid_1", "Crystalloid_24", "Pressors_1", "Pressors_24", "Sedatives_1_bin", "Sedatives_24_bin"] as const

export type ReportRole = keyof typeof REPORT_SCHEMAS
export const REPORT_ROLES = Object.freeze(Object.keys(REPORT_SCHEMAS) as ReportRole[])
export type ReportKey = Readonly<{ scope: 'preparation'; population: null } | { scope: 'population'; population: FitKey['population'] }>
export type ReportContext = Readonly<Record<typeof REPORT_CONTEXT_FIELDS[number], string>>
export interface AcceptedReport {
  readonly key: ReportKey
  readonly state: 'accepted'
  readonly expectedContext: ReportContext
  readonly files: Readonly<Partial<Record<ReportRole, ArtifactReference>>>
}
export interface UnavailableReport {
  readonly key: ReportKey
  readonly state: 'pending' | 'failed' | 'inference_unavailable'
  readonly reasonCode: string
}
export type SupplementReport = AcceptedReport | UnavailableReport
export type SupplementProfile = Readonly<
  { key: FitKey; state: 'available'; profileId: string; file: ArtifactReference }
  | { key: FitKey; state: 'unavailable'; reasonCode: string }
>
export interface SupplementManifest {
  readonly schemaVersion: typeof SUPPLEMENT_SCHEMA
  readonly releaseId: string
  readonly coreManifestSha256: string
  readonly datasetKind: DatasetKind
  readonly diagnosticOnly: boolean
  readonly scientificApproved: boolean
  readonly publicationApproved: boolean
  readonly reports: readonly SupplementReport[]
  readonly profiles: readonly SupplementProfile[]
  readonly methods: ArtifactReference
}
export interface ValidatedSupplement {
  readonly manifest: SupplementManifest
  readonly release: ValidatedRelease
}
interface PackedTable {
  readonly context: TableRow
  readonly columns: readonly string[]
  readonly rows: readonly (readonly TableCell[])[]
}
export interface ReportTable extends PackedTable {
  readonly schemaVersion: typeof REPORT_TABLE_SCHEMA
  readonly releaseId: string
  readonly reportKey: ReportKey
  readonly role: ReportRole
  readonly sourceSha256: string
}
export interface ProfileTable extends PackedTable {
  readonly schemaVersion: typeof PROFILE_TABLE_SCHEMA
  readonly releaseId: string
  readonly key: FitKey
  readonly profileId: string
  readonly sourceSha256: string
}

export const METHOD_SHAPE = {
  MeanModel: { BASE: 'texts', BASE_FULLComparison: 'text', FULLAdds: 'texts', Fit: 'text', Optimizer: 'text', ReferenceProfile: 'text', SedativeEncoding: 'text', Time: 'text', TreatmentLimitations: 'text' },
  AuthoritativeInference: { Changes: 'text', Endpoint: 'text', Estimator: 'text', Holm: 'text', Intervals: 'text', Levels: 'text', ModelPoints: 'text', Pairwise: 'text', ScalarDF: 'text', JointTests: { ENDPOINT_HETEROGENEITY: 'text', MAIN: 'text', Method: 'text', WHOLE_TRAJECTORY_INTERACTION: 'text' } },
  Availability: { AvailableCategory: 'text', Failed: 'text', LevelChangePrecision: 'text', MissingEncoding: 'text', Prefit: 'text', StructuralIU: 'text', UnavailablePlannedCategory: 'text' },
  IdentityAndEligibility: { CanonicalEvent: 'text', FactorEligibility: 'text', FirstEvent: 'text', MeasurementReconciliation: 'text', NoFollowing: 'text', PhysicalUnit: 'text', PriorHistory: 'text', PriorUnitCovariate: 'text' },
  ObservedPairedSummaries: { Estimand: 'text', LaterWindows: 'text', Multiplicity: 'text', Uncertainty: 'text', Weighting: 'text', WindowEndpoints: 'text', AfterWindow: 'numbers', BeforeWindow: 'numbers' },
  CountsAndFlow: { Limits: 'text', ModelRows: 'text', OverlappingReasons: 'text', PeopleEventsAdmissionsUnits: 'text', ReportOrigin: 'text', TimeSupport: 'text' },
  ResidualAndOtherLimits: 'texts',
} as const

export const METHOD_SHAPE_V2 = {
  AuthoritativeInference: METHOD_SHAPE.AuthoritativeInference,
  Availability: METHOD_SHAPE.Availability,
  IdentityAndEligibility: METHOD_SHAPE.IdentityAndEligibility,
  ObservedPairedSummaries: METHOD_SHAPE.ObservedPairedSummaries,
  ResidualAndOtherLimits: METHOD_SHAPE.ResidualAndOtherLimits,
  PrimaryModel: 'text', ComparisonModel: 'text', ReferenceProfile: 'text', SedativeEncoding: 'text',
  TimeSupport: 'text', LOESS: 'text', RetentionReplay: 'text',
} as const

type MethodValue<T> = T extends 'text' ? string : T extends 'texts' ? readonly string[] : T extends 'numbers' ? readonly number[] : T extends object ? { readonly [K in keyof T]: MethodValue<T[K]> } : never
export type MethodsSections = MethodValue<typeof METHOD_SHAPE> | MethodValue<typeof METHOD_SHAPE_V2>
export interface Methods {
  readonly schemaVersion: typeof METHODS_SCHEMA | typeof METHODS_SCHEMA_V2
  readonly releaseId: string
  readonly sourceSha256: string
  readonly sections: MethodsSections
}

export class SupplementValidationError extends Error {
  constructor(readonly code: string) { super(code); this.name = 'SupplementValidationError' }
}
function check(value: unknown, code: string): asserts value {
  if (!value) throw new SupplementValidationError(code)
}
function own(value: object, key: string) { return Object.prototype.hasOwnProperty.call(value, key) }
function object(value: unknown): Record<string, unknown> {
  check(typeof value === 'object' && value !== null && !Array.isArray(value), 'INVALID_SUPPLEMENT_OBJECT')
  const prototype: unknown = Object.getPrototypeOf(value)
  check(prototype === Object.prototype || prototype === null, 'UNSAFE_SUPPLEMENT_OBJECT')
  for (const name of Reflect.ownKeys(value)) {
    check(typeof name === 'string' && !['__proto__', 'constructor', 'prototype'].includes(name), 'UNSAFE_SUPPLEMENT_FIELD')
    const descriptor = Object.getOwnPropertyDescriptor(value, name)
    check(descriptor !== undefined && descriptor.enumerable && own(descriptor, 'value'), 'UNSAFE_SUPPLEMENT_FIELD')
  }
  return value as Record<string, unknown>
}
function list(value: unknown): readonly unknown[] {
  check(Array.isArray(value) && Object.getPrototypeOf(value) === Array.prototype, 'INVALID_SUPPLEMENT_ARRAY')
  check(Reflect.ownKeys(value).length === value.length + 1, 'INVALID_SUPPLEMENT_ARRAY')
  for (let index = 0; index < value.length; index += 1) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index))
    check(descriptor !== undefined && descriptor.enumerable && own(descriptor, 'value'), 'INVALID_SUPPLEMENT_ARRAY')
  }
  return value
}
function exact(value: unknown, keys: readonly string[]): Record<string, unknown> {
  const input = object(value)
  check(Object.keys(input).length === keys.length && keys.every(key => own(input, key)), 'SUPPLEMENT_FIELDS_MISMATCH')
  return input
}
function text(value: unknown, nonempty = false): string {
  check(typeof value === 'string' && value.length <= 8192 && !value.includes('\0') && (!nonempty || value.length > 0), 'INVALID_SUPPLEMENT_TEXT')
  return value
}
function token(value: unknown): string {
  check(typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(value), 'INVALID_SUPPLEMENT_IDENTIFIER')
  return value
}
function hash(value: unknown): string {
  check(typeof value === 'string' && /^[a-f0-9]{64}$/.test(value), 'INVALID_SUPPLEMENT_HASH')
  return value
}
function reason(value: unknown): string {
  check(typeof value === 'string' && /^[A-Z][A-Z0-9_]{0,95}$/.test(value), 'INVALID_SUPPLEMENT_REASON')
  return value
}
function reportKey(value: unknown): ReportKey {
  const key = exact(value, ['scope', 'population'])
  check((key.scope === 'preparation' && key.population === null)
    || (key.scope === 'population' && POPULATIONS.includes(key.population as FitKey['population'])), 'INVALID_REPORT_KEY')
  return Object.freeze({ scope: key.scope, population: key.population }) as ReportKey
}
function fitKey(value: unknown): FitKey {
  const key = exact(value, ['population', 'model', 'factor', 'outcome'])
  check(POPULATIONS.includes(key.population as FitKey['population']) && MODELS.includes(key.model as FitKey['model'])
    && FACTORS.includes(key.factor as FitKey['factor']) && OUTCOMES.includes(key.outcome as FitKey['outcome']), 'INVALID_PROFILE_KEY')
  return Object.freeze({ ...key }) as unknown as FitKey
}
function fitId(key: FitKey) { return JSON.stringify([key.population, key.model, key.factor, key.outcome]) }
function reportId(key: ReportKey) { return JSON.stringify([key.scope, key.population]) }
function reference(value: unknown, releaseId: string): ArtifactReference {
  const ref = exact(value, ['releaseId', 'url', 'sha256'])
  check(ref.releaseId === releaseId && typeof ref.url === 'string'
    && ref.url.startsWith('data/releases/' + releaseId + '/') && ref.url.endsWith('.json')
    && ref.url.split('/').every(part => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(part)), 'INVALID_SUPPLEMENT_REFERENCE')
  return Object.freeze({ releaseId, url: ref.url, sha256: hash(ref.sha256) })
}
export function reportRoles(key: ReportKey): readonly ReportRole[] {
  return key.scope === 'preparation' ? PREPARATION_REPORT_ROLES : POPULATION_REPORT_ROLES
}
function reportContext(value: unknown, key: ReportKey, release: ValidatedRelease): ReportContext {
  const input = exact(value, REPORT_CONTEXT_FIELDS)
  const result = Object.fromEntries(REPORT_CONTEXT_FIELDS.map(field => [field, text(input[field], true)])) as Record<typeof REPORT_CONTEXT_FIELDS[number], string>
  for (const field of ['RunId', 'AnalysisSpecId', 'ReportRunId', 'ExportId', 'Bundle', 'PopulationId', 'DisclosureStatus'] as const) token(result[field])
  for (const field of ['InputSnapshotId', 'CodeHash', 'ConfigHash', 'ExportCodeHash'] as const) hash(result[field])
  for (const field of ['ReportCodeHash', 'ReportConfigHash'] as const) {
    if (!(key.scope === 'preparation' && result[field] === 'NOT_APPLICABLE')) hash(result[field])
  }
  check(result.CohortMode === release.manifest.datasetKind, 'REPORT_COHORT_MISMATCH')
  if (key.scope === 'population') check(result.PopulationId === key.population, 'REPORT_POPULATION_MISMATCH')
  return Object.freeze(result)
}

/** Check independently bound metadata; file-byte digests are checked by the loader. */
export function validateSupplementManifest(value: unknown, release: ValidatedRelease, coreSha256: string): ValidatedSupplement {
  const input = exact(value, ['schemaVersion', 'releaseId', 'coreManifestSha256', 'datasetKind', 'diagnosticOnly', 'scientificApproved', 'publicationApproved', 'reports', 'profiles', 'methods'])
  check(input.schemaVersion === SUPPLEMENT_SCHEMA, 'UNSUPPORTED_SUPPLEMENT_SCHEMA')
  const coreDigest = hash(coreSha256)
  check(hash(input.coreManifestSha256) === coreDigest, 'CORE_MANIFEST_HASH_MISMATCH')
  if (release.manifestSha256 !== undefined) check(release.manifestSha256 === coreDigest, 'CORE_MANIFEST_HASH_MISMATCH')
  const core = release.manifest
  check(input.releaseId === core.releaseId && input.datasetKind === core.datasetKind
    && input.diagnosticOnly === core.diagnosticOnly && input.scientificApproved === core.scientificApproved
    && input.publicationApproved === core.publicationApproved, 'SUPPLEMENT_RELEASE_MISMATCH')
  check(Array.isArray(input.reports) && input.reports.length === 4, 'REPORT_UNIVERSE_INCOMPLETE')
  check(release.plannedUniverseComplete && core.jobs.length === 252
    && Array.isArray(input.profiles) && input.profiles.length === core.jobs.length, 'PROFILE_UNIVERSE_INCOMPLETE')
  const paths = new Set<string>()
  for (const job of core.jobs) if (job.state === 'accepted') for (const ref of Object.values(job.files)) if (ref) paths.add(ref.url)
  function uniqueReference(raw: unknown) {
    const ref = reference(raw, core.releaseId)
    check(!paths.has(ref.url), 'DUPLICATE_SUPPLEMENT_ASSET_PATH'); paths.add(ref.url)
    return ref
  }
  const seenReports = new Set<string>()
  const reports: SupplementReport[] = list(input.reports).map(raw => {
    const item = object(raw), key = reportKey(item.key), id = reportId(key)
    check(!seenReports.has(id), 'DUPLICATE_REPORT_KEY'); seenReports.add(id)
    if (item.state === 'accepted') {
      exact(item, ['key', 'state', 'expectedContext', 'files'])
      const expectedContext = reportContext(item.expectedContext, key, release)
      const roles = reportRoles(key), rawFiles = exact(item.files, roles)
      const files = Object.fromEntries(roles.map(role => [role, uniqueReference(rawFiles[role])]))
      return Object.freeze({ key, state: 'accepted', expectedContext, files: Object.freeze(files) })
    }
    exact(item, ['key', 'state', 'reasonCode'])
    check(item.state === 'pending' || item.state === 'failed' || item.state === 'inference_unavailable', 'INVALID_REPORT_STATE')
    return Object.freeze({ key, state: item.state, reasonCode: reason(item.reasonCode) })
  })
  if (release.mode === 'production') check(reports.every(report => report.state === 'accepted'), 'PUBLICATION_REPORTS_INCOMPLETE')
  const jobs = new Map(core.jobs.map(job => [fitId(job.key), job])), seenProfiles = new Set<string>()
  const profiles: SupplementProfile[] = list(input.profiles).map(raw => {
    const item = object(raw), key = fitKey(item.key), id = fitId(key), job = jobs.get(id)
    check(job !== undefined && !seenProfiles.has(id), 'PROFILE_PLAN_MISMATCH'); seenProfiles.add(id)
    if (item.state === 'available') {
      exact(item, ['key', 'state', 'profileId', 'file'])
      check(job.state === 'accepted', 'PROFILE_FOR_UNACCEPTED_FIT')
      return Object.freeze({ key, state: 'available', profileId: token(item.profileId), file: uniqueReference(item.file) })
    }
    exact(item, ['key', 'state', 'reasonCode'])
    check(item.state === 'unavailable', 'INVALID_PROFILE_STATE')
    check(!(release.mode === 'production' && job.state === 'accepted'), 'PUBLICATION_PROFILE_UNAVAILABLE')
    return Object.freeze({ key, state: 'unavailable', reasonCode: reason(item.reasonCode) })
  })
  const methods = uniqueReference(input.methods)
  const manifest: SupplementManifest = Object.freeze({ schemaVersion: SUPPLEMENT_SCHEMA, releaseId: core.releaseId, coreManifestSha256: coreDigest,
    datasetKind: core.datasetKind, diagnosticOnly: core.diagnosticOnly, scientificApproved: core.scientificApproved, publicationApproved: core.publicationApproved,
    reports: Object.freeze(reports), profiles: Object.freeze(profiles), methods })
  return Object.freeze({ manifest, release })
}

function packed(input: Record<string, unknown>, characters: readonly string[], numbers: readonly string[]): PackedTable {
  const contextInput = object(input.context), header = [...characters, ...numbers], names = new Set(header), numeric = new Set(numbers)
  check(names.size === header.length, 'DUPLICATE_SUPPLEMENT_SCHEMA_FIELD')
  const context: Record<string, TableCell> = Object.create(null) as Record<string, TableCell>
  function typed(name: string, value: unknown): TableCell {
    check(names.has(name), 'UNEXPECTED_SUPPLEMENT_COLUMN')
    if (!numeric.has(name)) return text(value)
    check(value === null || (typeof value === 'number' && Number.isFinite(value)), 'INVALID_SUPPLEMENT_NUMBER')
    return value
  }
  for (const [name, value] of Object.entries(contextInput)) context[name] = typed(name, value)
  check(Array.isArray(input.columns) && Array.isArray(input.rows), 'INVALID_PACKED_TABLE')
  const columns = list(input.columns).map(name => { check(typeof name === 'string' && names.has(name), 'UNEXPECTED_SUPPLEMENT_COLUMN'); return name })
  check(new Set(columns).size === columns.length && columns.every(name => !own(context, name)), 'SUPPLEMENT_COLUMN_OVERLAP')
  const expected = header.filter(name => !own(context, name))
  check(columns.length === expected.length && columns.every((name, index) => name === expected[index]), 'SUPPLEMENT_HEADER_MISMATCH')
  const rows = list(input.rows).map(raw => {
    const values = list(raw)
    check(values.length === columns.length, 'SUPPLEMENT_ROW_WIDTH_MISMATCH')
    return Object.freeze(Array.from(values, (value, index) => typed(columns[index]!, value)))
  })
  return Object.freeze({ context: Object.freeze(context), columns: Object.freeze(columns), rows: Object.freeze(rows) })
}
export function supplementRows(table: PackedTable): readonly TableRow[] {
  return Object.freeze(table.rows.map(values => Object.freeze(Object.fromEntries([
    ...Object.entries(table.context), ...table.columns.map((name, index) => [name, values[index]!] as const),
  ]))))
}

export function validateReportTable(value: unknown, supplement: ValidatedSupplement, requestedKey: ReportKey, requestedRole: ReportRole): ReportTable {
  const requested = reportKey(requestedKey)
  const selected = supplement.manifest.reports.find(report => reportId(report.key) === reportId(requested))
  check(selected?.state === 'accepted' && own(REPORT_SCHEMAS, requestedRole) && selected.files[requestedRole] !== undefined, 'REPORT_NOT_AVAILABLE')
  const input = exact(value, ['schemaVersion', 'releaseId', 'reportKey', 'role', 'sourceSha256', 'context', 'columns', 'rows'])
  check(input.schemaVersion === REPORT_TABLE_SCHEMA, 'UNSUPPORTED_REPORT_TABLE_SCHEMA')
  const key = reportKey(input.reportKey)
  check(input.releaseId === supplement.manifest.releaseId && reportId(key) === reportId(requested) && input.role === requestedRole, 'REPORT_TABLE_IDENTITY_MISMATCH')
  const schema = REPORT_SCHEMAS[requestedRole]
  const table = packed(input, [...REPORT_CONTEXT_FIELDS, ...schema.characterFields], schema.numericFields)
  if (table.rows.length === 0) exact(table.context, REPORT_CONTEXT_FIELDS)
  const rows = table.rows.length ? supplementRows(table) : [table.context]
  for (const row of rows) for (const field of REPORT_CONTEXT_FIELDS) {
    check(own(row, field) && row[field] === selected.expectedContext[field], 'REPORT_ORIGINAL_IDENTITY_MISMATCH')
  }
  return Object.freeze({ schemaVersion: REPORT_TABLE_SCHEMA, releaseId: supplement.manifest.releaseId, reportKey: key, role: requestedRole, sourceSha256: hash(input.sourceSha256), ...table })
}

const PROFILE_MODEL_IDENTITY = ['RunId', 'AnalysisSpecId', 'CohortMode', 'PopulationId', 'FitId', 'InputSnapshotId', 'CodeHash', 'ConfigHash', 'DesignId', 'ProfileId', 'JobID', 'ProfileIdentityKind'] as const
export function validateProfileTable(value: unknown, supplement: ValidatedSupplement, requestedKey: FitKey, modelTable: ResultTable): ProfileTable {
  const requested = fitKey(requestedKey), id = fitId(requested)
  const selected = supplement.manifest.profiles.find(profile => fitId(profile.key) === id)
  check(selected?.state === 'available', 'PROFILE_NOT_AVAILABLE')
  check(modelTable.releaseId === supplement.manifest.releaseId && fitId(fitKey(modelTable.key)) === id, 'PROFILE_MODEL_SCOPE_MISMATCH')
  const input = exact(value, ['schemaVersion', 'releaseId', 'key', 'profileId', 'sourceSha256', 'context', 'columns', 'rows'])
  check(input.schemaVersion === PROFILE_TABLE_SCHEMA, 'UNSUPPORTED_PROFILE_TABLE_SCHEMA')
  const key = fitKey(input.key)
  check(input.releaseId === supplement.manifest.releaseId && fitId(key) === id && input.profileId === selected.profileId, 'PROFILE_TABLE_IDENTITY_MISMATCH')
  const numeric = key.model === 'FULL' ? [...PROFILE_BASE_NUMERIC_FIELDS, ...PROFILE_FULL_NUMERIC_FIELDS] : PROFILE_BASE_NUMERIC_FIELDS
  const table = packed(input, [...PROFILE_CONTEXT_FIELDS, ...PROFILE_CLASS_FIELDS], numeric)
  check(table.rows.length === 1 && table.columns.length === 0 && table.rows[0]!.length === 0, 'PROFILE_SINGLE_CONTEXT_ROW_REQUIRED')
  const row = table.context
  for (const field of PROFILE_MODEL_IDENTITY) {
    check(own(modelTable.context, field) && typeof modelTable.context[field] === 'string' && modelTable.context[field] !== ''
      && row[field] === modelTable.context[field], 'PROFILE_ORIGINAL_IDENTITY_MISMATCH')
  }
  check(row.ProfileId === selected.profileId && row.CohortMode === supplement.manifest.datasetKind && row.PopulationId === key.population
    && row.Model === key.model && row.VitalCode === key.outcome
    && (row.FactorName === key.factor || (key.factor === 'MAIN' && row.FactorName === 'NONE')), 'PROFILE_SCOPE_MISMATCH')
  for (const field of ['Model', 'FactorName', 'VitalCode'] as const) if (own(modelTable.context, field)) {
    check(row[field] === modelTable.context[field], 'PROFILE_ORIGINAL_IDENTITY_MISMATCH')
  }
  for (const field of ['InputSnapshotId', 'CodeHash', 'ConfigHash', 'SourceProfileSHA256'] as const) hash(row[field])
  return Object.freeze({ schemaVersion: PROFILE_TABLE_SCHEMA, releaseId: supplement.manifest.releaseId, key, profileId: selected.profileId, sourceSha256: hash(input.sourceSha256), ...table })
}

type MethodShape = 'text' | 'texts' | 'numbers' | { readonly [key: string]: MethodShape }
function methodValue(value: unknown, shape: MethodShape): unknown {
  if (shape === 'text') return text(value, true)
  if (shape === 'texts' || shape === 'numbers') {
    check(Array.isArray(value) && value.length > 0, 'INVALID_METHOD_LIST')
    return Object.freeze(Array.from(list(value), item => {
      if (shape === 'texts') return text(item, true)
      check(typeof item === 'number' && Number.isFinite(item), 'INVALID_METHOD_NUMBER')
      return item
    }))
  }
  const input = exact(value, Object.keys(shape))
  return Object.freeze(Object.fromEntries(Object.entries(shape).map(([key, fieldShape]) => [key, methodValue(input[key], fieldShape)])))
}
export function validateMethods(value: unknown, supplement: ValidatedSupplement): Methods {
  const input = exact(value, ['schemaVersion', 'releaseId', 'sourceSha256', 'sections'])
  check((input.schemaVersion === METHODS_SCHEMA || input.schemaVersion === METHODS_SCHEMA_V2) && input.releaseId === supplement.manifest.releaseId, 'METHODS_IDENTITY_MISMATCH')
  const schemaVersion = input.schemaVersion as typeof METHODS_SCHEMA | typeof METHODS_SCHEMA_V2
  return Object.freeze({ schemaVersion, releaseId: supplement.manifest.releaseId, sourceSha256: hash(input.sourceSha256),
    sections: methodValue(input.sections, schemaVersion === METHODS_SCHEMA ? METHOD_SHAPE : METHOD_SHAPE_V2) as MethodsSections })
}
