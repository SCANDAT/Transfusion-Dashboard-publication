"""Check denominators, strata and inferential status in aggregate reports."""
from __future__ import annotations
import csv, hashlib, io, json, math, re, stat
from pathlib import Path
from collections import defaultdict
import numpy as np
from scipy.stats import t
from exact_numeric import parse_number, ExactNumericError
from covariance_numeric_checks import CovarianceNumericalError, check_variance_se, check_covariance_entry, check_covariance_matrix, check_linear_reconstruction, check_pairwise_variance, covariance_dot_error
from aggregate_report_schema import CONTEXT, S, PROTOCOL, MANIFEST_COLUMNS, POPULATIONS, OUTCOMES, FACTORS, roles
from aggregate_report_schema import COMPUTED_PREDICATES, COMPUTED_STATUSES, UNRESOLVED_PREDICATES, FREEZE_PREDICATE, FREEZE_LABELS, MANIFEST_UNRESOLVED, DONATION_DATE_PARSERS, UNIT_STATUS, OXYGEN_FLAG_FIELD, OXYGEN_FLAG_STATUS

class Rejected(ValueError):

    def __init__(self, code):
        self.code = code
        super().__init__(code)

def require(ok, code):
    if not ok:
        raise Rejected(code)

def near(x, y, code='NUMERICAL_MISMATCH', atol=1e-08, rtol=1e-08):
    require(x is not None and y is not None and math.isclose(x, y, abs_tol=atol, rel_tol=rtol), code)

def number(x, *, allow_legacy_decimal=False):
    try:
        value = parse_number(x, allow_legacy_decimal=allow_legacy_decimal)
    except ExactNumericError as error:
        raise Rejected(error.code) from None
    return None if math.isnan(value) else value

def integer(x):
    return x is not None and 0 <= x <= 2 ** 53 and (x == int(x))

def unique(rows, keys):
    out = {}
    for r in rows:
        k = tuple((r[f] for f in keys))
        require(k not in out, 'DUPLICATE_ROW_KEY')
        out[k] = r
    return out

def context_valid(c):
    require(isinstance(c, dict) and set(c) == set(CONTEXT), 'EXPECTED_CONTEXT_REQUIRED')
    require(all((isinstance(v, str) and 0 < len(v) <= 64 for v in c.values())), 'EXPECTED_CONTEXT_INVALID')
    for k in ('RunId', 'ExportId'):
        require(bool(re.fullmatch('[0-9a-f]{32}', c[k])), 'EXPECTED_CONTEXT_INVALID')
    for k in ('CodeHash', 'ConfigHash', 'ExportCodeHash'):
        require(bool(re.fullmatch('[0-9a-f]{64}', c[k])), 'EXPECTED_CONTEXT_INVALID')
    require(c['CohortMode'] in ('development_sample', 'full_cohort') and c['DisclosureStatus'] == 'PRIVATE_UNREVIEWED', 'EXPECTED_SCOPE_INVALID')
    if c['Bundle'] == 'PREPARATION':
        require(all((c[k] == 'NOT_APPLICABLE' for k in ('ReportRunId', 'ReportCodeHash', 'ReportConfigHash'))), 'REPORT_BINDING_NOT_APPLICABLE_REQUIRED')
    else:
        require(bool(re.fullmatch('[0-9a-f]{32}', c['ReportRunId'])) and all((bool(re.fullmatch('[0-9a-f]{64}', c[k])) for k in ('ReportCodeHash', 'ReportConfigHash'))), 'REPORT_BINDING_REQUIRED')
    require(c['Bundle'] == 'PREPARATION' and c['PopulationId'] == 'GLOBAL_PREPARATION' or (c['Bundle'] == 'POPULATION' and c['PopulationId'] in POPULATIONS), 'EXPECTED_SCOPE_INVALID')
POPULATION_STATUSES = ('AVAILABLE', 'BLOCKED_COVERAGE_UNVERIFIED')
MEDICATION_NEGATIVE_FLAGS = {'Crystalloid_1': 'NNegativeCrystalloid1Flag', 'Crystalloid_24': 'NNegativeCrystalloid24Flag', 'Pressors_1': 'NNegativePressors1Flag', 'Pressors_24': 'NNegativePressors24Flag', 'Sedatives_1': 'NNegativeSedatives1Flag', 'Sedatives_24': 'NNegativeSedatives24Flag'}

def population_status_check(rows):
    pops = unique(rows, ('ReportedPopulationId',))
    require(set(pops) == {(x,) for x in POPULATIONS}, 'POPULATION_SET_INVALID')
    for (pid,), r in pops.items():
        require(r['PopulationStatus'] in POPULATION_STATUSES, 'POPULATION_STATUS_INVALID')
        if r['PopulationStatus'] == 'AVAILABLE':
            require(integer(r['NEvents']) and integer(r['NPersons']) and (r['NPersons'] <= r['NEvents']), 'POPULATION_COUNTS_INVALID')
        else:
            require(pid == 'NO_FOLLOWING_UNIT_12H' and r['NEvents'] is None and (r['NPersons'] is None), 'BLOCKED_POPULATION_COUNTS_INVALID')
    main = pops['PRIMARY',]
    first = pops['FIRST_EVENT',]
    nofollow = pops['NO_FOLLOWING_UNIT_12H',]
    require(first['NEvents'] == first['NPersons'] == main['NPersons'], 'POPULATION_NESTING_INVALID')
    if nofollow['PopulationStatus'] == 'AVAILABLE':
        require(nofollow['NEvents'] <= main['NEvents'] and nofollow['NPersons'] <= main['NPersons'], 'POPULATION_NESTING_INVALID')
    return pops

def unit_status_check(tables):
    require(all((r['UnitStatus'] == UNIT_STATUS for r in tables['pipeline_identity'])), 'UNIT_STATUS_RELABELED')

def preparation_labels_check(tables, cohort_mode):
    """Truthful label rules: unresolved semantics are never PASS; freeze follows the cohort's configured ROOT decision."""
    require(cohort_mode in FREEZE_LABELS, 'EXPECTED_SCOPE_INVALID')
    freeze_status, freeze_label = FREEZE_LABELS[cohort_mode]
    status = unique(tables['prepare_status'], ('Predicate',))
    require(set(status) == {(p,) for p in COMPUTED_PREDICATES + UNRESOLVED_PREDICATES + (FREEZE_PREDICATE,)}, 'PREPARATION_PREDICATE_SET_INVALID')
    for p in COMPUTED_PREDICATES:
        require(status[p,]['Status'] in COMPUTED_STATUSES, 'PREPARATION_STATUS_INVALID')
    for p in UNRESOLVED_PREDICATES:
        require(status[p,]['Status'] == 'UNRESOLVED', 'UNRESOLVED_SEMANTICS_RELABELED')
    require(status[FREEZE_PREDICATE,]['Status'] == freeze_status, 'SCIENTIFIC_FREEZE_LABEL_INVALID')
    for r in tables['prepare_manifest']:
        require(all((r[k] == v for k, v in MANIFEST_UNRESOLVED.items())), 'UNRESOLVED_SEMANTICS_RELABELED')
        require(r['ScientificFreeze'] == freeze_label, 'SCIENTIFIC_FREEZE_LABEL_INVALID')
        require(r['DonationDateUnit'] in DONATION_DATE_PARSERS, 'DONATION_DATE_PARSER_INVALID')

def oxygen_label_check(tables):
    oxygen = [r for r in tables['qa_processing_status'] if r['Field'] == OXYGEN_FLAG_FIELD]
    require(len(oxygen) == 1 and oxygen[0]['Status'] == OXYGEN_FLAG_STATUS, 'OXYGEN_UNIT_LABEL_UNSUPPORTED')
    require(all((r['NOxygenAbove100Flag'] is None for r in tables['qa_outcome_counts'])), 'OXYGEN_UNIT_LABEL_UNSUPPORTED')

def preparation_check(tables, cohort_mode):
    flow = unique(tables['source_flow'], ('Stage',))
    expected = {'SOURCE_INDEX_ROWS', 'ROW_ELIGIBLE', 'DISTINCT_SOURCE_EVENTS', 'ADMISSION_ACCEPTED_ROWS', 'ADMISSION_ACCEPTED_EVENTS', 'HISTORY_ACCEPTED_EVENTS', 'CANONICAL_RECONCILED_ROWS', 'RBC_LEDGER_SOURCE_ROWS', 'RBC_LEDGER_UNIQUE_UNITS', 'LINKED_INDEX_UNITS'}
    require({k[0] for k in flow} == expected, 'SOURCE_FLOW_STAGES_INVALID')
    counts = {k[0]: v['Count'] for k, v in flow.items()}
    for r in tables['source_flow'] + tables['source_exclusions']:
        require(integer(r['Count']) and r['DataScope'] == 'PREPARATION_FROM_SOURCE_INDEX_PERSONS', 'SOURCE_FLOW_VALUE_INVALID')
    unique(tables['source_exclusions'], ('Stage', 'CountingUnit', 'ReasonCode'))
    ex = defaultdict(float)
    for r in tables['source_exclusions']:
        ex[r['Stage']] += r['Count']
    for whole, part, exc in [('SOURCE_INDEX_ROWS', 'ROW_ELIGIBLE', 'SOURCE_ROW_ELIGIBILITY'), ('ROW_ELIGIBLE', 'ADMISSION_ACCEPTED_ROWS', 'ADMISSION_LINK'), ('ADMISSION_ACCEPTED_EVENTS', 'HISTORY_ACCEPTED_EVENTS', 'HISTORY_ELIGIBILITY')]:
        near(counts[whole], counts[part] + ex[exc], 'SOURCE_FLOW_PARTITION_INVALID', 0, 0)
    for a, b in [('CANONICAL_RECONCILED_ROWS', 'ADMISSION_ACCEPTED_ROWS'), ('ADMISSION_ACCEPTED_EVENTS', 'DISTINCT_SOURCE_EVENTS'), ('RBC_LEDGER_UNIQUE_UNITS', 'RBC_LEDGER_SOURCE_ROWS')]:
        require(counts[a] <= counts[b], 'SOURCE_FLOW_ORDER_INVALID')
    pops = population_status_check(tables['population_counts'])
    main = pops['PRIMARY',]
    near(main['NEvents'], counts['HISTORY_ACCEPTED_EVENTS'], 'POPULATION_FLOW_MISMATCH', 0, 0)
    unique(tables['followup_counts'], ('FollowupStatus',))
    require(all((integer(r['NEvents']) and integer(r['NPersons']) and (r['NPersons'] <= r['NEvents']) for r in tables['followup_counts'])), 'FOLLOWUP_COUNTS_INVALID')
    require(sum((r['NEvents'] for r in tables['followup_counts'])) == main['NEvents'], 'FOLLOWUP_PARTITION_INVALID')
    preparation_labels_check(tables, cohort_mode)
    preparation_flow_check(tables)
FLOW_STAGES = (('SOURCE_IDENTITY', 'MISSING_SOURCE_EVENT_KEY', 'INDEX_EXTRACT_ROWS'), ('SOURCE_OUTCOME', 'OUTSIDE_DECLARED_OUTCOMES', 'INDEX_EXTRACT_ROWS'), ('SOURCE_MEASUREMENT_TIME', 'MISSING_MEASUREMENT_TIME', 'INDEX_EXTRACT_ROWS'), ('SOURCE_WINDOW', 'OUTSIDE_ANALYSIS_WINDOW', 'INDEX_EXTRACT_ROWS'), ('ADMISSION_VALID_HISTORY', 'INVALID_ADMISSION_HISTORY', 'INDEX_EXTRACT_ROWS'), ('ADMISSION_CONTAINS_INDEX', 'NO_ADMISSION_CONTAINS_INDEX', 'INDEX_EXTRACT_ROWS'), ('ADMISSION_UNIQUE_MATCH', 'MULTIPLE_ADMISSIONS_CONTAIN_INDEX', 'INDEX_EXTRACT_ROWS'), ('ADMISSION_STORED_ID', 'STORED_CLINICAL_ID_MISMATCH', 'INDEX_EXTRACT_ROWS'), ('ADMISSION_STORED_BOUNDS', 'STORED_ADMISSION_BOUNDS_MISMATCH', 'INDEX_EXTRACT_ROWS'), ('HISTORY_INDEX_PRESENT', 'INDEX_EVENT_ABSENT_FROM_LEDGER', 'CANONICAL_EVENT_ROWS'), ('HISTORY_PRIOR_CLEAR', 'AMBIGUOUS_PRIOR_UNIT_ADMISSION', 'CANONICAL_EVENT_ROWS'), ('HISTORY_12H', 'PREVIOUS_RBC_WITHIN_OR_AT_MINUS12H', 'CANONICAL_EVENT_ROWS'))

def preparation_flow_check(tables):
    rows = tables['flow_metrics']
    metrics = unique(rows, ('MetricID',))
    expected = {}
    counts = {}

    def add(key, stage, unit, overlap, den):
        expected[key] = (stage, unit, overlap, den)
    for stage, reason, rowunit in FLOW_STAGES:
        for subset in ('ALL', 'PASS', 'FAIL', reason):
            for suffix in ('ROWS', 'PERSONS', 'EVENTS', 'NO_PERSON_ROWS', 'NO_EVENT_ROWS'):
                unit = {'PERSONS': 'KNOWN_PERSONS', 'EVENTS': 'KNOWN_EVENT_KEYS'}.get(suffix, rowunit)
                overlap = 'NOT_ADDITIVE'
                if suffix == 'ROWS' and subset in ('PASS', 'FAIL'):
                    overlap = 'DISJOINT_PASS_FAIL_ROWS'
                if suffix == 'ROWS' and subset == reason:
                    overlap = 'FIRST_FAILURE_ROWS_ONLY'
                denominator = f'{stage}_{subset}_ROWS' if suffix.startswith('NO_') else f'{stage}_ALL_{suffix}'
                add(f'{stage}_{subset}_{suffix}', stage, unit, overlap, denominator)
        for unit, suffix in (('KNOWN_PERSONS', 'PERSONS'), ('KNOWN_EVENT_KEYS', 'EVENTS')):
            for label in ('FULLY_LOST', 'PARTLY_RETAINED', 'UNTOUCHED', 'ANY_AFFECTED'):
                add(f'{stage}_{label}_{unit}', stage, unit, 'LOST_PLUS_PARTLY_RETAINED' if label == 'ANY_AFFECTED' else 'DISJOINT_ENTITY_PARTITION', f'{stage}_ALL_{suffix}')
    for label in ('MISSING_CLINICAL_ID', 'MISSING_EVENT_TIME'):
        add(f'SOURCE_{label}_ROWS', 'SOURCE_IDENTITY', 'INDEX_EXTRACT_ROWS', 'NOT_ADDITIVE', 'SOURCE_IDENTITY_ALL_ROWS')
    for suffix in ('ROWS', 'PERSONS', 'EVENTS', 'NO_PERSON_ROWS', 'NO_EVENT_ROWS'):
        unit = {'PERSONS': 'KNOWN_PERSONS', 'EVENTS': 'KNOWN_EVENT_KEYS'}.get(suffix, 'CANONICAL_ANALYSIS_ROWS')
        add('CANONICAL_RECONCILED_ALL_' + suffix, 'CANONICAL_RECONCILED', unit, 'NOT_ADDITIVE', 'CANONICAL_RECONCILED_ALL_' + ('ROWS' if suffix.startswith('NO_') else suffix))
    require({k[0] for k in metrics} == set(expected), 'FLOW_METRIC_UNIVERSE_INVALID')
    for (key,), r in metrics.items():
        require(r['FlowProtocol'] == 'NATIVE_PREPARATION_REASON_FLOW_V1' and r['DataScope'] == 'PREPARATION_FROM_SOURCE_INDEX_PERSONS', 'FLOW_PROTOCOL_INVALID')
        require(tuple((r[k] for k in ('Stage', 'CountingUnit', 'Overlap', 'DenominatorID'))) == expected[key] and integer(r['Count']), 'FLOW_METRIC_SEMANTICS_INVALID')
        counts[key] = r['Count']
    for stage, reason, _ in FLOW_STAGES:
        get = lambda subset, suffix: counts[f'{stage}_{subset}_{suffix}']
        for suffix in ('ROWS', 'NO_PERSON_ROWS', 'NO_EVENT_ROWS'):
            require(get('ALL', suffix) == get('PASS', suffix) + get('FAIL', suffix), 'FLOW_ROW_PARTITION_INVALID')
        for suffix in ('ROWS', 'PERSONS', 'EVENTS', 'NO_PERSON_ROWS', 'NO_EVENT_ROWS'):
            require(get('FAIL', suffix) == get(reason, suffix), 'FLOW_FIRST_FAILURE_INVALID')
        for subset in ('ALL', 'PASS', 'FAIL', reason):
            require(get(subset, 'PERSONS') <= get(subset, 'EVENTS') + get(subset, 'NO_EVENT_ROWS') <= get(subset, 'ROWS') + get(subset, 'NO_EVENT_ROWS'), 'FLOW_ENTITY_COUNT_ORDER_INVALID')
            require(get(subset, 'NO_PERSON_ROWS') <= get(subset, 'NO_EVENT_ROWS') <= get(subset, 'ROWS'), 'FLOW_MISSING_ID_COUNT_ORDER_INVALID')
        for unit, suffix in (('KNOWN_PERSONS', 'PERSONS'), ('KNOWN_EVENT_KEYS', 'EVENTS')):
            part = lambda label: counts[f'{stage}_{label}_{unit}']
            require(get('ALL', suffix) == part('FULLY_LOST') + part('PARTLY_RETAINED') + part('UNTOUCHED') and get('PASS', suffix) == part('PARTLY_RETAINED') + part('UNTOUCHED') and (get('FAIL', suffix) == part('ANY_AFFECTED') == part('FULLY_LOST') + part('PARTLY_RETAINED')), 'FLOW_ENTITY_PARTITION_INVALID')
    for start, end in ((0, 4), (4, 9), (9, 12)):
        for i in range(start + 1, end):
            for suffix in ('ROWS', 'PERSONS', 'EVENTS', 'NO_PERSON_ROWS', 'NO_EVENT_ROWS'):
                require(counts[f'{FLOW_STAGES[i - 1][0]}_PASS_{suffix}'] == counts[f'{FLOW_STAGES[i][0]}_ALL_{suffix}'], 'FLOW_SEQUENTIAL_RISK_SET_INVALID')
    checks = unique(tables['flow_checks'], ('Check',))
    require(set(checks) == {(x,) for x in ('NATIVE_FIRST_FAILURE_REASONS_COVERED', 'KNOWN_ENTITY_PARTITIONS_EXACT', 'AGGREGATE_COUNTS_NONNEGATIVE_INTEGERS')}, 'FLOW_CHECK_SET_INVALID')
    require(all((r['Status'] == 'PASS' and r['FlowProtocol'] == 'NATIVE_PREPARATION_REASON_FLOW_V1' and (r['DataScope'] == 'PREPARATION_FROM_SOURCE_INDEX_PERSONS') for r in checks.values())), 'FLOW_NATIVE_CHECK_FAILED')

def required_counts(rows, fields, code='REQUIRED_COUNT_INVALID'):
    for row in rows:
        require(all((integer(row.get(field)) for field in fields)), code)

def descriptors_check(tables):
    count_fields = {'rdd_patient_sex': ('No_of_Patients', 'Denominator'), 'rdd_patient_age_groups': ('Count', 'Denominator'), 'rdd_patient_ward': ('No_of_Patients', 'Denominator'), 'rdd_units_per_person': ('No_of_Patients', 'Denominator', 'Linked_Index_Units'), 'rdd_patient_age': ('N_Age', 'N_Missing_Age', 'NPersons'), 'rdd_patient_saps': ('NPersons', 'NAvailable', 'NMissing', 'NInvalid', 'NNotRequested'), 'rdd_unit_categories': ('No_of_Transfused_Units', 'NTotalUnits', 'NValid', 'NMissing', 'NInvalid', 'NEligibleUnits', 'NExcluded')}
    for role, fields in count_fields.items():
        required_counts(tables[role], fields, 'DESCRIPTOR_COUNT_INVALID')
    counts = unique(tables['rdd_cohort_counts'], ('CountingUnit',))
    require(set(counts) == {(s,) for s in ('PERSONS', 'ICU_ADMISSIONS', 'INDEX_EVENTS', 'LINKED_PHYSICAL_UNITS')}, 'COHORT_COUNT_SET_INVALID')
    require(all((integer(r['Count']) for r in counts.values())), 'COHORT_COUNTS_NONINTEGER')
    n = counts['PERSONS',]['Count']
    e = counts['INDEX_EVENTS',]['Count']
    u = counts['LINKED_PHYSICAL_UNITS',]['Count']
    require(integer(n) and n > 0 and (n <= counts['ICU_ADMISSIONS',]['Count'] <= e <= u), 'COHORT_COUNT_ORDER_INVALID')
    for role, countfield in [('rdd_patient_sex', 'No_of_Patients'), ('rdd_patient_age_groups', 'Count'), ('rdd_patient_ward', 'No_of_Patients'), ('rdd_units_per_person', 'No_of_Patients')]:
        rows = tables[role]
        require(sum((r[countfield] for r in rows)) == n, 'DESCRIPTOR_DENOMINATOR_INVALID')
        for r in rows:
            require(integer(r[countfield]) and r['Denominator'] == n, 'DESCRIPTOR_DENOMINATOR_INVALID')
            if 'Percent' in r:
                near(r['Percent'], 100 * r[countfield] / n, 'DESCRIPTOR_PERCENT_INVALID')
            if 'Relative_Frequency' in r:
                near(r['Relative_Frequency'], r[countfield] / n, 'DESCRIPTOR_FREQUENCY_INVALID')
    require(sum((r['Linked_Index_Units'] * r['No_of_Patients'] for r in tables['rdd_units_per_person'])) == u, 'UNIT_COUNT_DISTRIBUTION_INVALID')
    age = tables['rdd_patient_age'][0]
    require(age['N_Age'] + age['N_Missing_Age'] == n and age['NPersons'] == n, 'AGE_DENOMINATOR_INVALID')
    saps = tables['rdd_patient_saps'][0]
    require(saps['NPersons'] == n and saps['NAvailable'] + saps['NMissing'] + saps['NInvalid'] + saps['NNotRequested'] == n, 'SAPS_DENOMINATOR_INVALID')
    byfactor = defaultdict(list)
    for r in tables['rdd_unit_categories']:
        byfactor[r['Factor']].append(r)
    require(set(byfactor) == {'DonorHb', 'Storage', 'DonorSex', 'DonationWeekday', 'DonorParity'}, 'UNIT_FACTOR_SET_INVALID')
    for factor, rows in byfactor.items():
        unique(rows, ('CategoryCode',))
        require(sum((r['No_of_Transfused_Units'] for r in rows)) == u, 'UNIT_CATEGORY_PARTITION_INVALID')
        for r in rows:
            require(r['NTotalUnits'] == u and r['NValid'] + r['NMissing'] + r['NInvalid'] == r['NEligibleUnits'] and (r['NEligibleUnits'] + r['NExcluded'] == u), 'UNIT_CATEGORY_DENOMINATOR_INVALID')
            require(r['DenominatorDefinition'] == ('FEMALE_DONOR_LINKED_INDEX_UNITS' if factor == 'DonorParity' else 'ALL_LINKED_INDEX_UNITS'), 'UNIT_CATEGORY_DEFINITION_INVALID')
            if r['Eligible'] == 1:
                near(r['Percent'], 100 * r['No_of_Transfused_Units'] / r['NEligibleUnits'], 'UNIT_CATEGORY_PERCENT_INVALID')
            else:
                require(r['Eligible'] == 0 and r['Percent'] is None, 'EXCLUDED_UNIT_PERCENT_INVALID')
    return (n, e)

def qa_check(tables, pop):
    required_counts(tables['qa_covariate_missing'], ('NMissing', 'NNonmissing', 'NRows'), 'QA_COUNT_INVALID')
    required_counts(tables['qa_outcome_counts'], ('NRows',), 'QA_COUNT_INVALID')
    for role in (r for r in tables if r.startswith('qa_')):
        for r in tables[role]:
            require(r['AnalysisPopulationId'] == pop, 'QA_POPULATION_MISMATCH')
        if role not in ('qa_covariate_missing', 'qa_processing_status'):
            m = unique(tables[role], ('VitalCode',))
            require(set(m) == {(v,) for v in OUTCOMES}, 'QA_OUTCOME_SET_INVALID')
    covs = {'PatientAge', 'PatientSex', 'WardName', 'ICU_time', 'RBC_Count', 'Crystalloid_1', 'Crystalloid_24', 'Pressors_1', 'Pressors_24', 'Sedatives_1', 'Sedatives_24', 'TimeFromTransfusion'}
    m = unique(tables['qa_covariate_missing'], ('VitalCode', 'Variable'))
    require(set(m) == {(v, c) for v in OUTCOMES for c in covs}, 'MISSINGNESS_GRID_INVALID')
    outcome = {r['VitalCode']: r for r in tables['qa_outcome_counts']}
    for r in m.values():
        require(r['NMissing'] + r['NNonmissing'] == r['NRows'] == outcome[r['VitalCode']]['NRows'], 'MISSINGNESS_PARTITION_INVALID')
    oxygen_label_check(tables)
    for r in tables['qa_outcome_counts']:
        for var, field in MEDICATION_NEGATIVE_FLAGS.items():
            require(integer(r[field]) and r[field] + m[r['VitalCode'], var]['NMissing'] <= r['NRows'], 'MEDICATION_NEGATIVE_FLAG_INVALID')
    for role in ('qa_record_intervals', 'qa_source_value_quantiles'):
        for r in tables[role]:
            if r['CoverageStatus'] == 'NOT_AVAILABLE':
                require(all((r[f] is None for f in S[role].nums if f != 'OutcomeOrder')), 'UNAVAILABLE_SOURCE_FABRICATED')
            else:
                require(r['CoverageStatus'] == 'SUPPLIED_SOURCE_RECORDS_ONLY', 'SOURCE_COVERAGE_INVALID')
    for role in ('qa_value_quantiles', 'qa_source_value_quantiles'):
        for r in tables[role]:
            q = [r[f] for f in ('ValueP5', 'ValueP25', 'ValueP50', 'ValueP75', 'ValueP95')]
            if r['NValues'] is None or r['NValues'] == 0:
                require(all((x is None for x in q)), 'EMPTY_QUANTILES_INVALID')
            else:
                require(all((x is not None for x in q)) and q == sorted(q), 'QUANTILE_ORDER_INVALID')

def observed_check(tables, n, e):
    audit = dict(Protocol='OBSERVED_COVARIANCE_NUMERICAL_V1', StrictDiagonalChecks=0, MatrixChecks=0, ResolvedReconstructions=0, CancellationLimitedReconstructions=0)

    def numerical(function, *args, **kwargs):
        try:
            return function(*args, **kwargs)
        except CovarianceNumericalError as error:
            raise Rejected('OBSERVED_' + error.code) from None

    def record(certificate):
        audit['ResolvedReconstructions' if certificate.status == 'RESOLVED' else 'CancellationLimitedReconstructions'] += 1

    def sd(row, metric):
        field, status = metricfields[metric]
        return 0.0 if row[status] == 'ZERO_VARIANCE_UNAVAILABLE' else row[field]

    def dot(a, b, g):
        return numerical(covariance_dot_error, a, b, int(g))
    summaries = tables['observed_data_summary'] + tables['factor_observed_data_summary']
    m = unique(summaries, ('VitalCode', 'Factor', 'CategoryCode'))
    require(set(m) == {(v, f, c) for v in OUTCOMES for f, cats in FACTORS.items() for c in cats}, 'OBSERVED_CATEGORY_GRID_INVALID')
    method = tables['observed_manifest'][0]
    require(tuple((method[x] for x in ('PreLowerMinutes', 'PreUpperMinutes', 'PostLowerMinutes', 'PostUpperMinutes'))) == (-65, -55, 55, 65), 'OBSERVED_WINDOW_INVALID')
    require(method['Weighting'] == 'EQUAL_MEASUREMENT_THEN_PAIRED_EVENT' and method['PairingDefinition'] == 'ONE_PERSON_EVENT_OUTCOME_INTERSECTION', 'OBSERVED_WEIGHTING_INVALID')
    requested = method['InferenceApprovalStatus'] == 'PAIRED_INFERENCE_APPROVED'
    require(requested or method['InferenceApprovalStatus'] == 'NOT_REQUESTED', 'OBSERVED_APPROVAL_INVALID')
    if requested:
        require(method['ConfidenceLevel'] == 0.95, 'OBSERVED_CONFIDENCE_LEVEL_INVALID')
        require(method['ClusterUnit'] == 'VERIFIED_PERSON' and method['VarianceAdjustment'] == 'VADJUST_NONE_CLUSTER_G_OVER_G_1' and (method['IntervalDistribution'] == 'T_WITH_G_MINUS_1_DF') and (method['JointCovarianceSource'] == 'SAME_PAIRED_PERSON_SCORES') and (method['ResponseCentering'] == 'CATEGORY_CENTER_SHARED_MAX_CHANGE_SD'), 'OBSERVED_METHOD_INVALID')
    byfit = defaultdict(list)
    statuses = {'NOT_REQUESTED', 'NO_PAIRED_EVENTS', 'INSUFFICIENT_CATEGORY_PERSONS', 'INSUFFICIENT_RESIDUAL_INFORMATION', 'ZERO_VARIANCE_UNAVAILABLE', 'PAIRED_INFERENCE_APPROVED'}
    for key, r in m.items():
        byfit[key[:2]].append(r)
        for f in ('NEligibleEvents', 'NEligiblePatients', 'NPreAvailableEvents', 'NPostAvailableEvents', 'NDiff', 'NPairedPatients', 'NPreOnlyEvents', 'NPostOnlyEvents', 'NNeitherAvailableEvents', 'NPreWindowRecords', 'NPostWindowRecords', 'NPairedPreValues', 'NPairedPostValues'):
            require(integer(r[f]), 'OBSERVED_COUNTS_INVALID')
        require(r['NDiff'] + r['NPreOnlyEvents'] + r['NPostOnlyEvents'] + r['NNeitherAvailableEvents'] == r['NEligibleEvents'], 'OBSERVED_PAIR_PARTITION_INVALID')
        require(r['NDiff'] + r['NPreOnlyEvents'] == r['NPreAvailableEvents'] and r['NDiff'] + r['NPostOnlyEvents'] == r['NPostAvailableEvents'], 'OBSERVED_WINDOW_PARTITION_INVALID')
        require(r['NPairedPatients'] <= r['NDiff'] <= r['NEligibleEvents'] <= e and r['NEligiblePatients'] <= n, 'OBSERVED_DENOMINATOR_INVALID')
        for field in ('FitPersons', 'FitEvents', 'FitCategories'):
            require(integer(r[field]) if requested and r['NPairedPatients'] >= 2 else r[field] is None or integer(r[field]), 'OBSERVED_FIT_COUNT_INVALID')
        identity_supported = requested and r['NPairedPatients'] >= 2 and (r['FitPersons'] >= 2) and (r['FitEvents'] > r['FitCategories'])
        require(r['ScoreIdentityNorm'] is not None and r['ScoreIdentityNorm'] >= 0 if identity_supported else r['ScoreIdentityNorm'] is None, 'SCORE_IDENTITY_NORM_AVAILABILITY_INVALID')
        if r['NDiff'] == 0:
            require(all((r[f] is None for f in ('Pre_Mean', 'Post_Mean', 'Diff_Mean'))), 'EMPTY_OBSERVED_MEANS_INVALID')
        else:
            near(r['Diff_Mean'], r['Post_Mean'] - r['Pre_Mean'], 'OBSERVED_MEAN_DIFFERENCE_INVALID')
        for prefix, statusfield, df, lcl, ucl in [('Pre', 'Pre_InferenceStatus', 'Pre_DF', 'Pre_LCL', 'Pre_UCL'), ('Post', 'Post_InferenceStatus', 'Post_DF', 'Post_LCL', 'Post_UCL'), ('Diff', 'InferenceStatus', 'DF', 'Diff_LCL', 'Diff_UCL')]:
            st = r[statusfield]
            require(st in statuses, 'OBSERVED_STATUS_INVALID')
            expected_status = 'NOT_REQUESTED' if not requested else 'NO_PAIRED_EVENTS' if r['NDiff'] == 0 else 'INSUFFICIENT_CATEGORY_PERSONS' if r['NPairedPatients'] < 2 else 'INSUFFICIENT_RESIDUAL_INFORMATION' if r['FitPersons'] < 2 or r['FitEvents'] <= r['FitCategories'] else None
            require(st == expected_status if expected_status else st in ('PAIRED_INFERENCE_APPROVED', 'ZERO_VARIANCE_UNAVAILABLE'), 'OBSERVED_AVAILABILITY_STATUS_INVALID')
            vals = [r[f'{prefix}_SE'], r[df], r[lcl], r[ucl]]
            if st == 'PAIRED_INFERENCE_APPROVED':
                require(requested and r['NPairedPatients'] >= 2 and (r['FitPersons'] >= 2) and (r['FitEvents'] > r['FitCategories']) and all((x is not None for x in vals)) and (vals[0] > 0) and (vals[1] == r['FitPersons'] - 1), 'OBSERVED_SUPPORT_INVALID')
                crit = t.ppf(0.975, vals[1])
                near(vals[2], r[f'{prefix}_Mean'] - crit * vals[0], 'OBSERVED_CI_INVALID')
                near(vals[3], r[f'{prefix}_Mean'] + crit * vals[0], 'OBSERVED_CI_INVALID')
                if prefix == 'Diff':
                    near(r['PValue'], 2 * t.sf(abs(r['Diff_Mean'] / vals[0]), vals[1]), 'OBSERVED_P_INVALID', 0.0)
            else:
                require(all((x is None for x in vals)), 'UNAVAILABLE_UNCERTAINTY_PRESENT')
                if prefix == 'Diff':
                    require(r['PValue'] is None, 'UNAVAILABLE_P_PRESENT')
                if not requested:
                    require(st == 'NOT_REQUESTED', 'UNREQUESTED_INFERENCE_STATUS_INVALID')
    for rows in byfit.values():
        if requested:
            events = sum((r['NDiff'] for r in rows))
            k = sum((r['NDiff'] > 0 for r in rows))
            require(all((r['FitEvents'] == events and r['FitCategories'] == k for r in rows)), 'OBSERVED_FIT_COUNTS_INVALID')
            require(all((integer(r['FitPersons']) and r['FitPersons'] == rows[0]['FitPersons'] for r in rows)), 'OBSERVED_FIT_PERSONS_INVALID')
            require(max((r['NPairedPatients'] for r in rows)) <= rows[0]['FitPersons'] <= sum((r['NPairedPatients'] for r in rows)), 'OBSERVED_FIT_PERSONS_INVALID')
    pairmap = unique(tables['observed_pairwise'], ('VitalCode', 'Factor', 'CategoryA', 'CategoryB'))
    require(set(pairmap) == {(v, f, a, b) for v in OUTCOMES for f, cats in FACTORS.items() for a in cats for b in cats if a < b}, 'OBSERVED_PAIRWISE_GRID_INVALID')
    covariance = unique(tables['observed_covariance'], ('VitalCode', 'Factor', 'CategoryA', 'CategoryB'))
    joint = unique(tables['observed_joint_covariance'], ('VitalCode', 'Factor', 'CategoryA', 'CategoryB', 'MetricA', 'MetricB'))
    expected_cov = set()
    expected_joint = set()
    if requested:
        for (v, f), rows in byfit.items():
            fit = rows[0]
            if fit['FitPersons'] >= 2 and fit['FitEvents'] > fit['FitCategories']:
                cats = [r['CategoryCode'] for r in rows if r['NDiff'] > 0]
                expected_cov.update(((v, f, a, b) for a in cats for b in cats))
                expected_joint.update(((v, f, a, b, x, y) for a in cats for b in cats for x in ('PRE', 'POST', 'CHANGE') for y in ('PRE', 'POST', 'CHANGE')))
    require(set(covariance) == expected_cov and set(joint) == expected_joint, 'OBSERVED_COVARIANCE_GRID_INVALID')
    metricfields = {'PRE': ('Pre_SE', 'Pre_InferenceStatus'), 'POST': ('Post_SE', 'Post_InferenceStatus'), 'CHANGE': ('Diff_SE', 'InferenceStatus')}
    for key, r in joint.items():
        v, f, a, b, x, y = key
        ra = m[v, f, a]
        rb = m[v, f, b]
        sa = ra[metricfields[x][1]]
        sb = rb[metricfields[y][1]]
        expected = 'INSUFFICIENT_CATEGORY_PERSONS' if min(ra['NPairedPatients'], rb['NPairedPatients']) < 2 else 'ESTIMATED_ZERO_COVARIANCE' if 'ZERO_VARIANCE_UNAVAILABLE' in (sa, sb) else 'PAIRED_INFERENCE_APPROVED'
        require(r['InferenceStatus'] == expected, 'OBSERVED_COVARIANCE_STATUS_INVALID')
        if expected == 'PAIRED_INFERENCE_APPROVED':
            require(r['Covariance'] is not None and r['DF'] == ra['FitPersons'] - 1, 'OBSERVED_COVARIANCE_SUPPORT_INVALID')
            numerical(check_covariance_entry, r['Covariance'], joint[v, f, b, a, y, x]['Covariance'], sd(ra, x), sd(rb, y))
            if a == b and x == y:
                numerical(check_variance_se, r['Covariance'], sd(ra, x))
                audit['StrictDiagonalChecks'] += 1
        elif expected == 'ESTIMATED_ZERO_COVARIANCE':
            require(r['Covariance'] == 0 and r['DF'] is None, 'ESTIMATED_ZERO_COVARIANCE_INVALID')
            require(joint[v, f, b, a, y, x]['Covariance'] == 0, 'COVARIANCE_ASYMMETRIC')
        else:
            require(r['Covariance'] is None and r['DF'] is None, 'UNAVAILABLE_COVARIANCE_PRESENT')
        if x == y == 'CHANGE':
            c = covariance[v, f, a, b]
            require(c['InferenceStatus'] == r['InferenceStatus'], 'CHANGE_COVARIANCE_STATUS_MISMATCH')
            if r['Covariance'] is not None:
                numerical(check_covariance_entry, c['Covariance'], r['Covariance'], sd(ra, x), sd(rb, y))
                require(c['DF'] == r['DF'], 'CHANGE_COVARIANCE_DF_MISMATCH')
                if expected == 'ESTIMATED_ZERO_COVARIANCE':
                    require(c['Covariance'] == 0, 'ESTIMATED_ZERO_COVARIANCE_INVALID')
                elif a == b:
                    numerical(check_variance_se, c['Covariance'], sd(ra, x))
                    audit['StrictDiagonalChecks'] += 1
            else:
                require(c['Covariance'] is None and c['DF'] is None, 'UNAVAILABLE_CHANGE_COVARIANCE_PRESENT')
    for (v, f), rows in byfit.items():
        targets = [(r['CategoryCode'], x) for r in rows for x in metricfields if r[metricfields[x][1]] in ('PAIRED_INFERENCE_APPROVED', 'ZERO_VARIANCE_UNAVAILABLE')]
        if not targets:
            continue
        mat = np.array([[joint[v, f, a, b, x, y]['Covariance'] for b, y in targets] for a, x in targets])
        marginal = [sd(m[v, f, a], x) for a, x in targets]
        numerical(check_covariance_matrix, mat, marginal)
        audit['MatrixChecks'] += 1
        for ra in rows:
            a = ra['CategoryCode']
            if any(((a, z) not in targets for z in ('PRE', 'POST', 'CHANGE'))):
                continue
            sp = sd(ra, 'PRE')
            sq = sd(ra, 'POST')
            sc = sd(ra, 'CHANGE')
            g = ra['FitPersons']
            identity = ra['ScoreIdentityNorm']
            value = lambda x, y: joint[v, f, a, a, x, y]['Covariance']
            operands = [value('POST', 'POST'), value('PRE', 'PRE'), value('CHANGE', 'CHANGE'), value('POST', 'PRE'), value('POST', 'CHANGE'), value('PRE', 'CHANGE')]
            errors = [dot(sq, sq, g), dot(sp, sp, g), dot(sc, sc, g), dot(sq, sp, g), dot(sq, sc, g), dot(sp, sc, g)]
            norm_error = dot(math.fsum((sp, sq, sc)), 1.0, 1) + dot(identity, 1.0, g)
            record(numerical(check_linear_reconstruction, identity * identity, operands, [1.0, 1.0, 1.0, -2.0, -2.0, 2.0], operand_errors=errors, actual_error=2 * identity * norm_error + norm_error * norm_error))
        for a, x in targets:
            if x != 'CHANGE' or any(((a, z) not in targets for z in ('PRE', 'POST'))):
                continue
            ra = m[v, f, a]
            g = ra['FitPersons']
            for b, y in targets:
                rb = m[v, f, b]
                sy = sd(rb, y)
                sp = sd(ra, 'PRE')
                sq = sd(ra, 'POST')
                sc = sd(ra, 'CHANGE')
                val = lambda metric: joint[v, f, a, b, metric, y]['Covariance']
                identity = ra['ScoreIdentityNorm']
                actual_error = identity * sy + dot(identity, sy, g) + dot(sc, sy, g) + dot(math.fsum((sp, sq, sc)), sy, 1)
                record(numerical(check_linear_reconstruction, val('CHANGE'), [val('POST'), val('PRE')], [1.0, -1.0], operand_errors=[dot(sq, sy, g), dot(sp, sy, g)], actual_error=actual_error))
    for (v, f, a, b), r in pairmap.items():
        ra = m[v, f, a]
        rb = m[v, f, b]
        require((r['NEventsA'], r['NEventsB'], r['NPersonsA'], r['NPersonsB']) == (ra['NDiff'], rb['NDiff'], ra['NPairedPatients'], rb['NPairedPatients']), 'PAIRWISE_DENOMINATOR_INVALID')
        if ra['NDiff'] > 0 and rb['NDiff'] > 0:
            near(r['Estimate'], ra['Diff_Mean'] - rb['Diff_Mean'], 'PAIRWISE_ESTIMATE_INVALID')
        else:
            require(r['Estimate'] is None, 'EMPTY_PAIRWISE_ESTIMATE_INVALID')
        expected = 'NOT_REQUESTED' if not requested else 'NO_PAIRED_EVENTS' if min(ra['NDiff'], rb['NDiff']) == 0 else 'INSUFFICIENT_CATEGORY_PERSONS' if min(ra['NPairedPatients'], rb['NPairedPatients']) < 2 else 'INSUFFICIENT_RESIDUAL_INFORMATION' if ra['FitPersons'] < 2 or ra['FitEvents'] <= ra['FitCategories'] else None
        require(r['InferenceStatus'] == expected if expected else r['InferenceStatus'] in ('PAIRED_INFERENCE_APPROVED', 'ZERO_VARIANCE_UNAVAILABLE'), 'PAIRWISE_AVAILABILITY_STATUS_INVALID')
        if expected is None:
            aa = covariance[v, f, a, a]['Covariance']
            bb = covariance[v, f, b, b]['Covariance']
            ab = covariance[v, f, a, b]['Covariance']
            require(all((z is not None for z in (aa, bb, ab))), 'PAIRWISE_COVARIANCE_UNAVAILABLE')
            g = ra['FitPersons']
            sa = sd(ra, 'CHANGE')
            sb = sd(rb, 'CHANGE')
            errors = [dot(sa, sa, g), dot(sb, sb, g), dot(sa, sb, g)]
            if r['InferenceStatus'] == 'PAIRED_INFERENCE_APPROVED':
                require(all((r[z] is not None for z in ('StdErr', 'DF', 'Lower', 'Upper', 'PValue'))), 'PAIRWISE_INFERENCE_MISSING')
                record(numerical(check_pairwise_variance, r['StdErr'], aa, bb, ab, operand_errors=errors, actual_error=dot(r['StdErr'], r['StdErr'], g)))
                require(r['DF'] == g - 1, 'PAIRWISE_DF_INVALID')
                crit = t.ppf(0.975, r['DF'])
                near(r['Lower'], r['Estimate'] - crit * r['StdErr'], 'PAIRWISE_CI_INVALID')
                near(r['Upper'], r['Estimate'] + crit * r['StdErr'], 'PAIRWISE_CI_INVALID')
                near(r['PValue'], 2 * t.sf(abs(r['Estimate'] / r['StdErr']), r['DF']), 'PAIRWISE_P_INVALID', 0.0)
            else:
                record(numerical(check_linear_reconstruction, 0.0, [aa, bb, ab], [1.0, 1.0, -2.0], operand_errors=errors))
        if r['InferenceStatus'] != 'PAIRED_INFERENCE_APPROVED':
            require(all((r[z] is None for z in ('StdErr', 'DF', 'Lower', 'Upper', 'PValue'))), 'UNAVAILABLE_PAIRWISE_INFERENCE_PRESENT')
    return audit

def _validate_archive(directory, expected_context, *, export_started_ns=None, expected_files=None):
    context_valid(expected_context)
    require(isinstance(export_started_ns, int) and export_started_ns > 0 or isinstance(expected_files, dict), 'TRUSTED_FRESHNESS_REQUIRED')
    root = Path(directory)
    require(root.is_dir() and (not root.is_symlink()) and (not (root.stat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT if hasattr(root.stat(), 'st_file_attributes') else False)), 'DIRECTORY_INVALID')
    bindings = {}
    total = 0

    def read(role, columns, nums=()):
        nonlocal total
        filename = role + '.csv'
        p = root / filename
        st = p.stat(follow_symlinks=False)
        require(stat.S_ISREG(st.st_mode) and (not getattr(st, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 1024)), 'FILE_NOT_REGULAR')
        require(0 < st.st_size <= 64 * 2 ** 20, 'FILE_SIZE_INVALID')
        total += st.st_size
        require(total <= 256 * 2 ** 20, 'BUNDLE_SIZE_INVALID')
        if export_started_ns is not None:
            require(st.st_mtime_ns >= export_started_ns, 'STALE_EXPORT')
        raw = p.read_bytes()
        after = p.stat(follow_symlinks=False)
        require((st.st_size, st.st_mtime_ns) == (after.st_size, after.st_mtime_ns), 'FILE_CHANGED_DURING_READ')
        binding = {'sha256': hashlib.sha256(raw).hexdigest(), 'size': st.st_size}
        bindings[filename] = binding
        if expected_files is not None:
            require(expected_files.get(filename) == binding, 'FILE_BINDING_MISMATCH')
        reader = csv.DictReader(io.StringIO(raw.decode('utf-8-sig'), newline=''))
        require(tuple(reader.fieldnames or ()) == tuple(columns), 'CSV_SCHEMA_MISMATCH')
        rows = []
        for r in reader:
            require(None not in r and all((v is not None for v in r.values())), 'CSV_WIDTH_INVALID')
            require(all((r[k] == v for k, v in expected_context.items())), 'CONTEXT_MISMATCH')
            require(all((len(v) <= 1024 for v in r.values())), 'CELL_SIZE_INVALID')
            for k in nums:
                r[k] = number(r[k])
            rows.append(r)
            require(len(rows) <= 100000, 'ROW_LIMIT_EXCEEDED')
        return rows
    manifest = read('aggregate_manifest', MANIFEST_COLUMNS, ('RowCount', 'ColumnCount'))
    manifestmap = unique(manifest, ('Role',))
    bundle = expected_context['Bundle']
    empty = bundle == 'POPULATION' and set(manifestmap) == {(s,) for s in roles(bundle, True)}
    required = roles(bundle, empty)
    require(set(manifestmap) == {(s,) for s in required}, 'MANIFEST_ROLE_SET_INVALID')
    require({p.name for p in root.iterdir() if p.suffix.lower() == '.csv'} == {x + '.csv' for x in required} | {'aggregate_manifest.csv'}, 'UNDECLARED_CSV_PRESENT')
    tables = {}
    for role in required:
        schema = S[role]
        r = manifestmap[role,]
        require(r['Protocol'] == PROTOCOL and r['FileName'] == role + '.csv' and (r['NumericFormat'] == 'HEX16_IEEE754') and (r['TextEncoding'] == 'UTF-8') and (r['ExportStatus'] == 'EXPORTED_LOCAL_ONLY'), 'MANIFEST_METADATA_INVALID')
        require(integer(r['RowCount']) and r['ColumnCount'] == len(schema.columns), 'MANIFEST_DIMENSIONS_INVALID')
        table = read(role, schema.columns, schema.nums)
        tables[role] = table
        require(len(table) == r['RowCount'] and (schema.rows is None or len(table) == schema.rows), 'TABLE_CARDINALITY_INVALID')
    require(tables['pipeline_identity'][0]['ExecutionStatus'] == 'PREPARATION_COMPLETE', 'PREPARATION_NOT_COMPLETE')
    unit_status_check(tables)
    numerical_audit = {'Protocol': 'OBSERVED_COVARIANCE_NUMERICAL_V1', 'Status': 'NOT_APPLICABLE'}
    if bundle == 'PREPARATION':
        preparation_check(tables, expected_context['CohortMode'])
    else:
        require(tables['report_identity'][0]['ReportStatus'] == 'REPORTS_COMPLETE', 'REPORT_IDENTITY_INVALID')
        require(tables['report_status'][0]['Status'] == ('EMPTY_POPULATION' if empty else 'COMPLETE'), 'REPORT_STATUS_INVALID')
        unavail = unique(tables['report_unavailable'], ('Item',))
        require(set(unavail) == {('DIAGNOSIS_SUMMARY',), ('HOSPITAL_COUNT',)}, 'UNAVAILABLE_ITEMS_INVALID')
        reasons = {'DIAGNOSIS_SUMMARY': 'SOURCE_FIELD_NOT_ADAPTED_TO_REPORT_INTERFACE', 'HOSPITAL_COUNT': 'REVIEWED_WARD_TO_HOSPITAL_MAP_NOT_SUPPLIED'}
        for r in unavail.values():
            require(r['AvailabilityStatus'] == 'NOT_AVAILABLE' and r['ReasonCode'] == reasons[r['Item']], 'UNRESOLVED_SEMANTICS_RELABELED')
        populations = population_status_check(tables['population_counts'])
        selected = populations[expected_context['PopulationId'],]
        require(selected['PopulationStatus'] == 'AVAILABLE', 'SELECTED_POPULATION_BLOCKED')
        if empty:
            require(selected['NEvents'] == selected['NPersons'] == 0, 'EMPTY_POPULATION_COUNTS_INVALID')
        else:
            n, e = descriptors_check(tables)
            require((n, e) == (selected['NPersons'], selected['NEvents']), 'REPORT_PREPARATION_POPULATION_MISMATCH')
            qa_check(tables, expected_context['PopulationId'])
            numerical_audit = observed_check(tables, n, e)
    if expected_files is not None:
        require(set(expected_files) == set(bindings), 'FILE_BINDING_SET_MISMATCH')
    for name, binding in bindings.items():
        p = root / name
        st = p.stat(follow_symlinks=False)
        require(stat.S_ISREG(st.st_mode) and (not getattr(st, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 1024)), 'FILE_NOT_REGULAR')
        require(st.st_size == binding['size'] and hashlib.sha256(p.read_bytes()).hexdigest() == binding['sha256'], 'FILE_CHANGED_DURING_VALIDATION')
    digest = hashlib.sha256(json.dumps(bindings, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'status': 'AGGREGATE_ARCHIVE_VALIDATED', 'reason_code': 'PASS', 'Protocol': PROTOCOL, 'ArchiveContentDigest': digest, 'ExpectedFiles': bindings, 'NumericalAudit': numerical_audit}

def validate_archive(directory, expected_context, *, export_started_ns=None, expected_files=None):
    """Malformed exchange cells get fixed rejection codes; I/O/resource errors propagate."""
    try:
        return _validate_archive(directory, expected_context, export_started_ns=export_started_ns, expected_files=expected_files)
    except Rejected:
        raise
    except (KeyError, TypeError, IndexError, UnicodeError, csv.Error):
        raise Rejected('MALFORMED_AGGREGATE_ARCHIVE') from None
