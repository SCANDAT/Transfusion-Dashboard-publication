"""Check the model identity and reasons for unavailable inference."""
from __future__ import annotations
import hashlib, json, re
from pathlib import Path
from validate_model_exchange import require, integer, number, table, ExchangeError
from file_utils import regular_file, private_directory
PLAN_ROLES = tuple('cat_availability contrast_plan family_plan job_status'.split())
UNAVAILABLE_ROLES = ('identity', *PLAN_ROLES)
PLAN_FIELDS = {'cat_availability': 'CategoryCode CategoryIndex N_Scope N_Observations N_Patients N_Events Available AvailabilityReason', 'contrast_plan': 'ContrastID ContrastType CategoryCodeA CategoryCodeB CategoryIndexA CategoryIndexB Planned Active ExclusionReason FamilyID BeforeMinute AfterMinute', 'family_plan': 'FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage PlannedCategories AvailableCategories PlannedPairs ActivePairs PlanVersion', 'job_status': 'JobStatus ReasonCode FitAttempted N_Input N_Scope N_Used N_Patients N_Events N_Admissions AdmissionCountStatus ReferenceCount AvailableCategories PlanVersion'}
FACTOR_LEVELS = {'NONE': {1}, 'DonorHb_Cat': {1, 2, 3, 4, 5}, 'Storage_Cat': {1, 2, 3, 4, 5}, 'DonorSex': {1, 2}, 'DonorParity_Female': {0, 1}, 'wdy_donation': {1, 2, 3, 4, 5, 6, 7}}
UNAVAILABLE_REASONS = frozenset('EMPTY_MODEL_INPUT NO_OUTCOME_WINDOW_ROWS NO_COMPLETE_MODEL_ROWS INSUFFICIENT_COMPLETE_ROWS INSUFFICIENT_PERSONS DECLARED_REFERENCE_LEVEL_ABSENT FACTOR_AVAILABLE_CATEGORIES_LT2'.split())
UNAVAILABLE_PROTOCOL = 'RBC_EXPECTED_UNAVAILABLE_V1'

def _missing(value):
    return str(value).strip() in {'', '.'}

def validate_admission_count(row, expected):
    """Aggregate count on exact estimation rows; None is explicit synthetic absence."""
    status = row['AdmissionCountStatus']
    if status == 'NOT_PROVIDED_SYNTHETIC':
        require(expected.get('CohortMode') == 'synthetic' and _missing(row['N_Admissions']))
        return None
    require(status == 'COMPUTED' and (not _missing(row['N_Admissions'])))
    admissions = integer(row, 'N_Admissions')
    patients, events, used = [integer(row, key) for key in ('N_Patients', 'N_Events', 'N_Used')]
    require(0 <= patients <= admissions <= events <= used)
    require((used == 0) == (admissions == 0))
    return admissions

def reason_for(status, factor):
    counts = {key: integer(status, key) for key in 'N_Input N_Scope N_Used N_Patients N_Events ReferenceCount AvailableCategories'.split()}
    require(all((value >= 0 for value in counts.values())))
    require(counts['N_Input'] >= counts['N_Scope'] >= counts['N_Used'])
    require(max(counts['N_Patients'], counts['N_Events'], counts['ReferenceCount']) <= counts['N_Used'])
    require((counts['N_Used'] == 0) == (counts['N_Patients'] == 0) == (counts['N_Events'] == 0) == (counts['AvailableCategories'] == 0))
    for condition, reason in [(counts['N_Input'] == 0, 'EMPTY_MODEL_INPUT'), (counts['N_Scope'] == 0, 'NO_OUTCOME_WINDOW_ROWS'), (counts['N_Used'] == 0, 'NO_COMPLETE_MODEL_ROWS'), (counts['N_Used'] < 2, 'INSUFFICIENT_COMPLETE_ROWS'), (counts['N_Patients'] < 2, 'INSUFFICIENT_PERSONS'), (counts['ReferenceCount'] == 0, 'DECLARED_REFERENCE_LEVEL_ABSENT'), (factor != 'NONE' and counts['AvailableCategories'] < 2, 'FACTOR_AVAILABLE_CATEGORIES_LT2')]:
        if condition:
            return reason
    return 'NONE'

def validate_plan(rows_by_role, expected, *, fitted):
    factor = expected['FactorName']
    require(factor in FACTOR_LEVELS)
    planned = FACTOR_LEVELS[factor]
    cats = rows_by_role['cat_availability']
    require(len(cats) == len(planned))
    bycode = {integer(row, 'CategoryCode'): row for row in cats}
    require(set(bycode) == planned and len(bycode) == len(cats))
    available = {}
    scope_sum = 0
    used_sum = 0
    persons_sum = 0
    events_sum = 0
    for code, row in sorted(bycode.items()):
        scope, used, persons, events = [integer(row, key) for key in ('N_Scope', 'N_Observations', 'N_Patients', 'N_Events')]
        require(scope >= used >= 0 and 0 <= persons <= used and (0 <= events <= used))
        require((used == 0) == (persons == 0) == (events == 0))
        active = used > 0
        require(integer(row, 'Available') == int(active))
        require(row['AvailabilityReason'] == ('AVAILABLE' if active else 'LOST_AT_COMPLETE_CASE' if scope else 'ABSENT_IN_SCOPE'))
        if active:
            index = len(available) + 1
            require(integer(row, 'CategoryIndex') == index)
            available[code] = index
        else:
            require(_missing(row['CategoryIndex']))
        scope_sum += scope
        used_sum += used
        persons_sum += persons
        events_sum += events
    k = len(available)
    K = len(planned)
    family_id = expected['FitId'] + '.PAIRWISE'
    require(len(family_id) <= 128)
    families = rows_by_role['family_plan']
    require(len(families) == 1)
    family = families[0]
    require(family['FamilyID'] == family_id and family['FreezeStage'] == 'PRE_FIT' and (integer(family, 'PlanVersion') == 1))
    require(family['FamilyRole'] == ('PRIMARY' if expected['PopulationId'] == 'PRIMARY' and expected['Model'] == 'FULL' else 'SECONDARY'))
    require(all((family[key] == expected[key] for key in ('FactorName', 'Model', 'VitalCode'))))
    require(family['PAdjustment'] == 'Holm within family' and family['CIAdjustment'] == 'None: pointwise')
    require([integer(family, key) for key in ('PlannedCategories', 'AvailableCategories', 'PlannedPairs', 'ActivePairs')] == [K, k, K * (K - 1) // 2, k * (k - 1) // 2])
    wanted = {('WITHIN', c, None) for c in planned} | {('PAIRWISE', a, b) for a in planned for b in planned if a < b}
    contrasts = rows_by_role['contrast_plan']
    require(len(contrasts) == len(wanted))
    seen = set()
    for row in contrasts:
        kind = row['ContrastType']
        a = integer(row, 'CategoryCodeA')
        b = None if kind == 'WITHIN' else integer(row, 'CategoryCodeB')
        key = (kind, a, b)
        require(key in wanted and key not in seen)
        seen.add(key)
        require(row['ContrastID'] == ('W_' + str(a) if b is None else 'P_' + str(a) + '_' + str(b)))
        require(integer(row, 'Planned') == 1 and integer(row, 'BeforeMinute') == -60 and (integer(row, 'AfterMinute') == 60))
        active = a in available and (b is None or b in available)
        require(integer(row, 'Active') == int(active) and row['ExclusionReason'] == ('NONE' if active else 'CATEGORY_UNAVAILABLE'))
        require(row['FamilyID'] == ('NONE' if b is None else family_id))
        for code, field in [(a, 'CategoryIndexA'), (b, 'CategoryIndexB')]:
            if code in available:
                require(integer(row, field) == available[code])
            else:
                require(_missing(row[field]))
        if b is None:
            require(_missing(row['CategoryCodeB']))
    statuses = rows_by_role['job_status']
    require(len(statuses) == 1)
    status = statuses[0]
    require(integer(status, 'PlanVersion') == 1 and integer(status, 'AvailableCategories') == k)
    require(integer(status, 'N_Scope') >= scope_sum and integer(status, 'N_Used') == used_sum)
    require(integer(status, 'N_Patients') <= persons_sum and integer(status, 'N_Events') <= events_sum)
    require(integer(status, 'N_Patients') >= max((integer(r, 'N_Patients') for r in cats), default=0))
    require(integer(status, 'N_Events') >= max((integer(r, 'N_Events') for r in cats), default=0))
    if factor == 'NONE':
        require(integer(status, 'N_Scope') == scope_sum and integer(status, 'N_Patients') == persons_sum and (integer(status, 'N_Events') == events_sum))
    validate_admission_count(status, expected)
    reason = reason_for(status, factor)
    require(status['ReasonCode'] == reason)
    if fitted:
        require(reason == 'NONE' and status['JobStatus'] == 'FIT_CHECKS_PASSED' and (integer(status, 'FitAttempted') == 1))
    else:
        require(reason in UNAVAILABLE_REASONS and status['JobStatus'] == 'EXPECTED_UNAVAILABLE' and (integer(status, 'FitAttempted') == 0))
    return available

def _state(path):
    require(regular_file(path, 64 * 1024 * 1024))
    s = path.stat()
    return (s.st_size, s.st_mtime_ns, s.st_dev, s.st_ino)

def _validate_unavailable(folder, job, expected):
    from validate_model_archive import CONTEXT, MANIFEST_FIELDS, REQUIRED_EXPECTED
    folder = Path(folder)
    require(private_directory(folder))
    require(bool(re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,11}', job)))
    require(isinstance(expected, dict) and set(REQUIRED_EXPECTED) <= set(expected))
    require(all((isinstance(expected[k], str) and expected[k] for k in REQUIRED_EXPECTED)))
    require(expected['JobID'] == job and expected['FactorName'] in FACTOR_LEVELS)
    require(expected['CohortMode'] in {'synthetic', 'development_sample', 'full_cohort'})
    require(expected['Model'] in {'BASE', 'FULL'} and expected['VitalCode'] in {'ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE'})
    require(bool(re.fullmatch('[0-9a-f]{32}', expected['RunId'])))
    require(all((re.fullmatch('[0-9a-f]{64}', expected[k]) for k in ('CodeHash', 'ConfigHash'))))
    paths = {role: folder / (job + '_' + role + '.csv') for role in (*UNAVAILABLE_ROLES, 'archive_manifest')}
    names = {p.name for p in folder.iterdir()}
    required_names = {p.name for p in paths.values()}
    extras = names - required_names
    require(required_names <= names and len(extras) <= 1 and all((name.casefold() == (job + '_archive_manifest.sas7bdat').casefold() for name in extras)))
    optional = folder / next(iter(extras)) if extras else None
    binary_before = _state(optional) if optional is not None else None
    before = {role: _state(path) for role, path in paths.items()}
    identity, fields = table(folder, job, 'identity', CONTEXT)
    require(len(identity) == 1 and set(fields) == set(CONTEXT))
    identity = identity[0]
    require(all((identity[k] == expected[k] for k in REQUIRED_EXPECTED if k in CONTEXT)))
    require(identity['DFMethod'] == 'RESIDUAL' and integer(identity, 'BindingVersion') == 1)
    require(identity['SubjectAlias'] == 'PatientID' and identity['InferenceStatus'] == 'MODEL_BASED_CANDIDATE')
    require(identity['SubjectKeySource'] == ('SYNTHETIC_PERSON' if expected['CohortMode'] == 'synthetic' else 'PersonKey'))
    require(identity['DesignIdentityKind'] == 'ASSIGNED_ID_NOT_CONTENT_HASH' and identity['ProfileIdentityKind'] == 'ASSIGNED_ID_NOT_CONTENT_HASH')
    from validate_model_exchange import encoding_matches
    manifest, fields = table(folder, job, 'archive_manifest', (*CONTEXT, *MANIFEST_FIELDS))
    formats = {r['NumericFormat'] for r in manifest}
    require(len(formats) == 1)
    numeric_format = next(iter(formats))
    require(encoding_matches(manifest, numeric_format) and encoding_matches([identity], numeric_format))
    require(set(fields) == set(CONTEXT) | set(MANIFEST_FIELDS))
    require(len(manifest) == len(UNAVAILABLE_ROLES) and {r['Role'] for r in manifest} == set(UNAVAILABLE_ROLES))
    rows_by_role = {}
    for row in manifest:
        role = row['Role']
        require(all((row[k] == identity[k] for k in CONTEXT)))
        require(row['FileName'] == paths[role].name and row['SourceMember'].upper() == (job + '_' + role).upper())
        require(row['SourceKind'] == 'SOURCE_MODEL_TABLE' and row['NumericFormat'] == numeric_format and (row['TextEncoding'] == 'UTF-8'))
        require(row['ExportStatus'] == 'EXPORTED_LOCAL_ONLY' and row['ContentHashStatus'] == 'PENDING_EXTERNAL_HASH' and (integer(row, 'ArchiveVersion') == 1))
        required = set(CONTEXT) | set(PLAN_FIELDS.get(role, '').split())
        rows, fields = table(folder, job, role, required)
        require(set(fields) == required and len(rows) == integer(row, 'RowCount') and (len(fields) == integer(row, 'ColumnCount')))
        require(all((all((r[k] == identity[k] for k in CONTEXT)) for r in rows)))
        require(encoding_matches(rows, numeric_format))
        rows_by_role[role] = rows
    validate_plan(rows_by_role, expected, fitted=False)
    fingerprints = {}
    for role, path in paths.items():
        require(_state(path) == before[role])
        fingerprints[role] = hashlib.sha256(path.read_bytes()).hexdigest()
        require(_state(path) == before[role])
    if binary_before is not None:
        require(_state(optional) == binary_before)
    digest = hashlib.sha256(json.dumps(fingerprints, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return dict(status='EXPECTED_UNAVAILABLE_VALIDATED', protocol=UNAVAILABLE_PROTOCOL, ReasonCode=rows_by_role['job_status'][0]['ReasonCode'], ArchiveContentDigest=digest, ScientificApproval='NOT_GRANTED', FullRunReady=False)

def validate_unavailable(folder, job, expected):
    try:
        return _validate_unavailable(folder, job, expected)
    except Exception:
        raise ExchangeError('EXPECTED_UNAVAILABLE_VALIDATION_FAILED') from None
