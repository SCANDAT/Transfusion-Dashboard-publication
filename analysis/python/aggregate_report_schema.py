"""Columns and types for cohort counts and observed-outcome summaries."""
from dataclasses import dataclass
PROTOCOL = 'RBC_AGGREGATE_REPORTS_V2'
CONTEXT = tuple('RunId AnalysisSpecId CohortMode InputSnapshotId CodeHash ConfigHash ReportRunId ReportCodeHash ReportConfigHash ExportId ExportCodeHash Bundle PopulationId DisclosureStatus'.split())
SOURCE_CONTEXT = tuple('RunId AnalysisSpecId CohortMode'.split())
POPULATIONS = ('PRIMARY', 'FIRST_EVENT', 'NO_FOLLOWING_UNIT_12H')
OUTCOMES = ('ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE')
FACTORS = {'MAIN': (1,), 'DonorHb_Cat': tuple(range(1, 6)), 'Storage_Cat': tuple(range(1, 6)), 'DonorSex': (1, 2), 'DonorParity_Female': (0, 1), 'wdy_donation': tuple(range(1, 8))}

@dataclass(frozen=True)
class Schema:
    chars: tuple[str, ...]
    nums: tuple[str, ...]
    rows: int | None
    source: str

    @property
    def columns(self):
        return CONTEXT + self.chars + self.nums

def spec(chars='', nums='', rows=None, source='report'):
    return Schema(tuple(chars.split()), tuple(nums.split()), rows, source)
DEN = 'DenominatorDefinition DenominatorScope'
QCTX = 'SourcePopulationId AnalysisPopulationId'
OBS_CHARS = 'VitalCode Outcome Factor CategoryLabel Abbreviation FactorName FactorCategory InferenceMethod DenominatorDefinition Status InferenceStatus Pre_InferenceStatus Post_InferenceStatus InferenceApprovalStatus'
OBS_NUMS = 'OutcomeOrder CategoryCode NEligibleEvents NEligiblePatients NPreAvailableEvents NPostAvailableEvents NDiff NPairedPatients NPreOnlyEvents NPostOnlyEvents NNeitherAvailableEvents NPreWindowRecords NPostWindowRecords NPairedPreValues NPairedPostValues Pre_Mean Pre_SD Post_Mean Post_SD Diff_Mean Diff_SD WindowHalfWidthMinutes Diff_SE Diff_LCL Diff_UCL DF PValue Pre_SE Pre_DF Pre_LCL Pre_UCL Post_SE Post_DF Post_LCL Post_UCL FitPersons FitEvents FitCategories ScoreIdentityNorm'
COV_NUMS = 'CategoryA CategoryB Covariance DF FitPersons FitEvents FitCategories'
S = {'pipeline_identity': spec('CoverageStatus UnitStatus ExecutionStatus AgeBandDefinition SourceYearBoundsMeaning', 'SourceExtractFirstYear SourceExtractLastYear', 1, 'prepared'), 'source_flow': spec('Stage CountingUnit DataScope', 'Count', 10, 'prepared'), 'flow_metrics': spec('FlowProtocol MetricID Stage CountingUnit Overlap DenominatorID DataScope', 'Count', 343, 'prepared'), 'flow_checks': spec('FlowProtocol Check Status DataScope', '', 3, 'prepared'), 'source_exclusions': spec('Stage CountingUnit ReasonCode DataScope', 'Count', None, 'prepared'), 'prepare_manifest': spec('MappingEvidence ModelGroupingEvidence AdmissionPolicy ConcurrentPolicy UnitKeyDefinition PriorUnitDefinition IndexHistoryDefinition LedgerCoverage MedicationEncoding NativeOutcomeUnits ScientificFreeze DonationDateUnit RuleApproval MeasurementReconciliation MedicationReconciliation MedicationNormalizationRule AdmissionTimeDateStyle DataScope', 'NormalizationMeasurementCount NormalizationFieldCount Normalized_Crystalloid_1 Normalized_Crystalloid_24 Normalized_Pressors_1 Normalized_Pressors_24 Normalized_Sedatives_1 Normalized_Sedatives_24 NormalizationRelativeBound OriginalDistinctPayloadRows', 1, 'prepared'), 'prepare_status': spec('Predicate Status DataScope', '', 16, 'prepared'), 'population_counts': spec('ReportedPopulationId PopulationStatus CoverageScope CoverageEndBoundary FollowupDefinition', 'NEvents NPersons', 3, 'prepared'), 'followup_counts': spec('FollowupStatus CoverageScope CoverageEndBoundary FollowupDefinition', 'NEvents NPersons', None, 'prepared'), 'report_identity': spec('ReportStatus', '', 1, 'report'), 'report_status': spec('Status', '', 1, 'report'), 'report_unavailable': spec('Item AvailabilityStatus ReasonCode', '', 2, 'generated'), 'rdd_cohort_counts': spec('CountingUnit CountDefinition', 'Count', 4), 'rdd_patient_sex': spec('Patient_Sex ' + DEN, 'No_of_Patients Denominator Percent'), 'rdd_patient_age': spec(DEN, 'N_Age N_Missing_Age Mean_Age SD_Age Median_Age Q1_Age Q3_Age Min_Age Max_Age NPersons Denominator', 1), 'rdd_patient_age_groups': spec('BandCode BandLabel ' + DEN, 'BandOrder Count Denominator Percent', 9), 'rdd_patient_ward': spec('WardCode Status ' + DEN, 'No_of_Patients Denominator'), 'rdd_patient_saps': spec('Status ' + DEN, 'NAvailable Mean SD Median Q1 Q3 NPersons NMissing NInvalid NNotRequested Denominator', 1), 'rdd_unit_categories': spec('Factor CategoryCode CategoryLabel Status DenominatorDefinition', 'Eligible No_of_Transfused_Units NTotalUnits NEligibleUnits NValid NMissing NInvalid NExcluded Percent'), 'rdd_units_per_person': spec('UnitScope CountDefinition ' + DEN, 'Linked_Index_Units No_of_Patients Denominator Relative_Frequency'), 'rdd_anchor_audit': spec(DEN, 'NPersons PersonsWithChangingAge PersonsWithChangingSex PersonsWithEquivalentFirstTies Denominator', 1), 'rdd_manifest': spec('AnchorPolicy TiePolicy UnitScope AgeRangePolicy SAPSOption DescriptorStatus', '', 1), 'qa_outcome_counts': spec('VitalCode Outcome ' + QCTX, 'OutcomeOrder NRows NPatients NEvents NPatientsWithValue NEventsWithValue NMissingValue NMissingPersonKey NMissingEventKey NMissingDatetime NMissingTransDt NNegativeValueFlag NOxygenAbove100Flag NNegativeICUTimeFlag NNegativeRBCCountFlag NNonintegerRBCCountFlag NNegativeCrystalloid1Flag NNegativeCrystalloid24Flag NNegativePressors1Flag NNegativePressors24Flag NNegativeSedatives1Flag NNegativeSedatives24Flag NRowsMissingBaseCovariate NRowsMissingFullCovariate', 7), 'qa_covariate_missing': spec('VitalCode Outcome Variable MissingDefinition ' + QCTX, 'OutcomeOrder NRows NMissing NNonmissing', 84), 'qa_value_quantiles': spec('VitalCode Outcome QuantileMethod ValuePopulation ' + QCTX, 'OutcomeOrder NValues ValueP5 ValueP25 ValueP50 ValueP75 ValueP95', 7), 'qa_record_intervals': spec('VitalCode Outcome CoverageStatus DefinitionId SourceGroup GroupingDefinition QuantilePopulation ' + QCTX, 'OutcomeOrder NUniqueMeasurements NUniqueTimestamps NIntervals NNonpositiveIntervals NSeriesStarts NMissingDatetime NTimestampTieGroups NRecordsAtTiedTimestamps IntervalP5Seconds Q1IntervalSeconds MedianIntervalSeconds Q3IntervalSeconds IntervalP95Seconds', 7), 'qa_duplicate_records': spec('VitalCode Outcome DuplicateKeyDefinition ActionTaken ' + QCTX, 'OutcomeOrder NDuplicateGroups NRowsInDuplicateGroups NExtraDuplicateRows NMissingDuplicateKeyRows', 7), 'qa_processing_status': spec('Field Status Interpretation ActionTaken ' + QCTX, '', 11), 'qa_source_value_quantiles': spec('VitalCode Outcome CoverageStatus QuantileMethod ValuePopulation ' + QCTX, 'OutcomeOrder NValues ValueP5 ValueP25 ValueP50 ValueP75 ValueP95', 7), 'observed_data_summary': spec(OBS_CHARS, OBS_NUMS, 7), 'factor_observed_data_summary': spec(OBS_CHARS, OBS_NUMS, 147), 'observed_pairwise': spec('VitalCode Outcome Factor InferenceStatus InferenceMethod InferenceApprovalStatus', 'OutcomeOrder CategoryA CategoryB NEventsA NEventsB NPersonsA NPersonsB Estimate StdErr DF Lower Upper PValue FitPersons FitEvents FitCategories', 301), 'observed_covariance': spec('VitalCode Outcome Factor InferenceStatus InferenceApprovalStatus', COV_NUMS), 'observed_joint_covariance': spec('VitalCode Outcome Factor MetricA MetricB InferenceStatus InferenceApprovalStatus', COV_NUMS), 'observed_exclusions': spec('Factor ReasonCode InferenceApprovalStatus', 'NExcludedEvents NExcludedPatients'), 'observed_manifest': spec('WindowPolicy Weighting PairingDefinition ValueScale InferenceApprovalStatus AnalysisRole ClusterUnit VarianceAdjustment IntervalDistribution JointCovarianceSource ResponseCentering', 'PreLowerMinutes PreUpperMinutes PostLowerMinutes PostUpperMinutes ConfidenceLevel', 1)}
LABEL_RULES = 'RBC_AGGREGATE_TRUTHFUL_LABELS_V2'
COMPUTED_PREDICATES = ('CANONICAL_COHORT_NONEMPTY', 'ONE_MAIN_EVENT_PER_PERSON_TIME', 'FACTOR_ALL_UNIT_AGREEMENT_ENFORCED', 'LOGICAL_MEASUREMENT_KEYS_UNIQUE', 'PRIOR_INDEX_TIES_EXCLUDED', 'STRICT_MINUS12H_ELIGIBILITY_APPLIED', 'MEDICATION_MISSINGNESS_PRESERVED', 'MEDICATION_ROUNDOFF_POLICY_CHECKED', 'STORED_LEDGER_DATE_COMPATIBLE', 'MODEL_PERSON_ALIAS_CONFIGURED')
COMPUTED_STATUSES = ('PASS', 'NOT_CHECKED')
UNRESOLVED_PREDICATES = ('LEDGER_ASCERTAINMENT_COVERAGE', 'HISTORY_LOWER_COVERAGE_BOUNDARY', 'INHERITED_MEDICATION_ENCODING', 'NATIVE_OUTCOME_UNIT_SEMANTICS', 'DONATION_DATE_UNIT_SEMANTICS')
FREEZE_PREDICATE = 'FULL_RUN_SCIENTIFIC_FREEZE'
FREEZE_LABELS = {'development_sample': ('UNRESOLVED', 'NOT_READY_FOR_FULL_RUN'), 'full_cohort': ('ROOT_RECORDED', 'ROOT_RECORDED_FREEZE')}
MANIFEST_UNRESOLVED = {'LedgerCoverage': 'UNRESOLVED', 'MedicationEncoding': 'INHERITED_UNRESOLVED', 'NativeOutcomeUnits': 'UNRESOLVED'}
DONATION_DATE_PARSERS = ('DATE', 'DATETIME')
UNIT_STATUS = 'NO'
OXYGEN_FLAG_FIELD = 'OXYGEN_UNIT_DEPENDENT_FLAGS'
OXYGEN_FLAG_STATUS = 'UNAVAILABLE_UNVERIFIED_UNITS'
assert len(COMPUTED_PREDICATES) + len(UNRESOLVED_PREDICATES) + 1 == 16
PREPARATION_ROLES = tuple((k for k, s in S.items() if s.source == 'prepared'))
POPULATION_ROLES = ('pipeline_identity', 'population_counts') + tuple((k for k, s in S.items() if s.source != 'prepared'))

def roles(bundle, empty=False):
    if bundle == 'PREPARATION':
        return PREPARATION_ROLES
    if bundle == 'POPULATION':
        return ('pipeline_identity', 'population_counts', 'report_identity', 'report_status', 'report_unavailable') if empty else POPULATION_ROLES
    raise ValueError('BUNDLE_INVALID')
MANIFEST_COLUMNS = CONTEXT + tuple('Protocol Role FileName NumericFormat TextEncoding ExportStatus RowCount ColumnCount'.split())
for name, s in S.items():
    assert len(set((x.casefold() for x in s.columns))) == len(s.columns), name
