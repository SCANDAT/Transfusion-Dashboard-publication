"""Parse binary64 values from CSV and format aggregate dashboard tables."""
from __future__ import annotations
import csv,hashlib,io,json,math,re
from pathlib import Path,PurePosixPath

RELEASE_SCHEMA = 'transfusion-dashboard/release-v1'
TABLE_SCHEMA = 'transfusion-dashboard/table-v1'
ROLES = ('levels', 'changes', 'within', 'pairwise', 'joint')
POPULATIONS = ('PRIMARY', 'FIRST_EVENT', 'NO_FOLLOWING_UNIT_12H')
MODELS = ('BASE', 'FULL')
OUTCOMES = ('ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE')
FACTOR_MAP = {'NONE': 'MAIN', 'DonorHb_Cat': 'DonorHb_Cat', 'Storage_Cat': 'Storage_Cat', 'DonorSex': 'DonorSex', 'DonorParity_Female': 'DonorParity_Female', 'wdy_donation': 'wdy_donation'}
HEX = re.compile('[a-f0-9]{64}\\Z')
TOKEN = re.compile('[A-Za-z0-9][A-Za-z0-9._-]{0,95}\\Z')
REASON = re.compile('[A-Z][A-Z0-9_]{0,95}\\Z')
DECIMAL = re.compile('[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?\\Z')
SCALAR_STATUS = {'COMPUTED': 0, 'BASELINE_ZERO': 2, 'MOMENT_PRECISION_UNRESOLVED': 4}
JOINT_STATUS = {'COMPUTED': 0, 'LOW_EFFECTIVE_DF': 1, 'INSUFFICIENT_EFFECTIVE_DF': 2, 'NOT_APPLICABLE_SINGLE_CATEGORY': 3, 'MOMENT_PRECISION_UNRESOLVED': 4, 'DF2_SIGN_UNRESOLVED': 5}

class NormalizationError(ValueError):
    """Contains a fixed error code only, never input values or paths."""

def require(condition, code):
    if not condition:
        raise NormalizationError(code)

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def encode(value):
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')

def decode_json(raw):

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'DUPLICATE_JSON_KEY')
            result[key] = value
        return result
    try:
        return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(NormalizationError('NONFINITE_JSON')))
    except (UnicodeError, json.JSONDecodeError):
        raise NormalizationError('INVALID_JSON') from None

def read_hash_bound(path, expected_sha, expected_size=None):
    require(isinstance(expected_sha, str) and HEX.fullmatch(expected_sha), 'INVALID_BINDING_HASH')
    require(path.is_file() and (not path.is_symlink()), 'BOUND_FILE_MISSING')
    raw = path.read_bytes()
    require(expected_size is None or (type(expected_size) is int and len(raw) == expected_size), 'BOUND_SIZE_MISMATCH')
    require(digest(raw) == expected_sha, 'BOUND_HASH_MISMATCH')
    return raw

def relative_path(root, rel):
    require(isinstance(rel, str) and '\\' not in rel, 'INVALID_BOUND_PATH')
    parts = PurePosixPath(rel).parts
    require(parts and (not PurePosixPath(rel).is_absolute()) and all((re.fullmatch('[A-Za-z0-9_-][A-Za-z0-9._-]*', x) for x in parts)) and (rel == '/'.join(parts)), 'INVALID_BOUND_PATH')
    result = root.joinpath(*parts)
    current = root
    for part in parts:
        current = current / part
        require(not current.is_symlink() and (not (hasattr(current, 'is_junction') and current.is_junction())), 'LINKED_BOUND_PATH')
    require(result.resolve().is_relative_to(root.resolve()), 'BOUND_PATH_ESCAPE')
    return result

def fit_key(plan):
    require(plan.get('PopulationId') in POPULATIONS and plan.get('Model') in MODELS and (plan.get('FactorName') in FACTOR_MAP) and (plan.get('VitalCode') in OUTCOMES), 'UNMAPPED_FIT_KEY')
    require(re.fullmatch('M\\d{4}', plan.get('JobID', '')) is not None and re.fullmatch('C\\d{4}', plan.get('InferencePrefix', '')) is not None and TOKEN.fullmatch(plan.get('FitId', '')), 'INVALID_FIT_IDENTITY')
    require(plan['InferencePrefix'][1:] == plan['JobID'][1:], 'INFERENCE_PREFIX_MISMATCH')
    return {'population': plan['PopulationId'], 'model': plan['Model'], 'factor': FACTOR_MAP[plan['FactorName']], 'outcome': plan['VitalCode']}

def category_code(value):
    require(type(value) in (int, float) and math.isfinite(value) and (value == int(value)) and (abs(value) < 2 ** 53), 'INVALID_CATEGORY_CODE')
    return str(int(value))

def typed_number(value):
    if value == '.':
        return None
    require(isinstance(value, str) and DECIMAL.fullmatch(value), 'INVALID_NUMERIC_TOKEN')
    answer = float(value)
    require(math.isfinite(answer), 'NONFINITE_NUMERIC_TOKEN')
    return answer

def check_numeric_status(role, row):
    if role == 'joint':
        label = row.get('NumericStatus')
        require(label in JOINT_STATUS and row.get('JointStatus') == JOINT_STATUS[label], 'UNMAPPED_JOINT_STATUS')
    else:
        label = row.get('NumericStatus')
        require(label in SCALAR_STATUS and row.get('ContrastStatus') == SCALAR_STATUS[label], 'UNMAPPED_SCALAR_STATUS')
        if label == 'BASELINE_ZERO':
            require(role == 'changes' and row.get('TimeFromTransfusion') == -60, 'MISPLACED_BASELINE_ZERO')
        if label == 'MOMENT_PRECISION_UNRESOLVED':
            require(role in ('levels', 'changes'), 'MISPLACED_PRECISION_UNAVAILABLE')

def compact_table(header, rows, identity, context_schema, *, release_id, key, role, source_sha):
    for row in rows:
        check_numeric_status(role, row)
    if rows:
        context = {field: rows[0][field] for field in header if all((same_scalar(row[field], rows[0][field]) for row in rows))}
    else:
        context = {field: identity[field] for field in context_schema['Character'] + context_schema['Numeric']}
    columns = [field for field in header if field not in context]
    return {'schemaVersion': TABLE_SCHEMA, 'releaseId': release_id, 'key': key, 'role': role, 'sourceSha256': source_sha, 'context': context, 'columns': columns, 'rows': [[row[field] for field in columns] for row in rows]}

def same_scalar(left, right):
    return type(left) is type(right) and left == right and (not isinstance(left, float) or left != 0 or math.copysign(1, left) == math.copysign(1, right))
SUPPLEMENTS_SCHEMA = 'transfusion-dashboard/supplements-v1'
REPORT_TABLE_SCHEMA = 'transfusion-dashboard/report-table-v1'
PROFILE_TABLE_SCHEMA = 'transfusion-dashboard/profile-table-v1'
METHOD_FIELDS = {'MeanModel': {'BASE': [str], 'BASE_FULLComparison': str, 'FULLAdds': [str], 'Fit': str, 'Optimizer': str, 'ReferenceProfile': str, 'SedativeEncoding': str, 'Time': str, 'TreatmentLimitations': str}, 'AuthoritativeInference': {**{k: str for k in ('Changes', 'Endpoint', 'Estimator', 'Holm', 'Intervals', 'Levels', 'ModelPoints', 'Pairwise', 'ScalarDF')}, 'JointTests': {k: str for k in ('ENDPOINT_HETEROGENEITY', 'MAIN', 'Method', 'WHOLE_TRAJECTORY_INTERACTION')}}, 'Availability': {k: str for k in ('AvailableCategory', 'Failed', 'LevelChangePrecision', 'MissingEncoding', 'Prefit', 'StructuralIU', 'UnavailablePlannedCategory')}, 'IdentityAndEligibility': {k: str for k in ('CanonicalEvent', 'FactorEligibility', 'FirstEvent', 'MeasurementReconciliation', 'NoFollowing', 'PhysicalUnit', 'PriorHistory', 'PriorUnitCovariate')}, 'ObservedPairedSummaries': {**{k: str for k in ('Estimand', 'LaterWindows', 'Multiplicity', 'Uncertainty', 'Weighting', 'WindowEndpoints')}, 'AfterWindow': [float], 'BeforeWindow': [float]}, 'CountsAndFlow': {k: str for k in ('Limits', 'ModelRows', 'OverlappingReasons', 'PeopleEventsAdmissionsUnits', 'ReportOrigin', 'TimeSupport')}, 'ResidualAndOtherLimits': [str]}

def validate_methods(value, shape):
    if isinstance(shape, dict):
        require(isinstance(value, dict) and set(value) == set(shape), 'METHODS_SHAPE_MISMATCH')
        for key in shape:
            validate_methods(value[key], shape[key])
    elif isinstance(shape, list):
        require(isinstance(value, list) and bool(value), 'METHODS_LIST_INVALID')
        for item in value:
            validate_methods(item, shape[0])
    elif shape is str:
        require(isinstance(value, str) and 0 < len(value) <= 8192 and ('\x00' not in value), 'METHODS_TEXT_INVALID')
        require(re.search('(?i)([a-z]:[\\\\/]|\\\\\\\\|https?://|\\.py\\b|docs/|workstation/)', value) is None, 'METHODS_PRIVATE_METADATA')
    else:
        require(type(value) in (int, float) and math.isfinite(value), 'METHODS_NUMBER_INVALID')

def parse_csv(raw, header, numeric):
    require(len(header) == len(set(header)) and set(numeric) <= set(header), 'DUPLICATE_SCHEMA_FIELD')
    try:
        reader = csv.reader(io.StringIO(raw.decode('utf-8-sig'), newline=''), strict=True)
        require(next(reader) == header, 'ROLE_HEADER_MISMATCH')
        rows = []
        for cells in reader:
            require(len(cells) == len(header), 'CSV_ROW_WIDTH_MISMATCH')
            require(all(('\x00' not in value for value in cells)), 'INVALID_CHARACTER_CELL')
            rows.append({field: typed_number(value) if field in numeric else value for field, value in zip(header, cells)})
        return rows
    except (UnicodeError, csv.Error, StopIteration):
        raise NormalizationError('INVALID_ROLE_CSV') from None

def pack_columns(header, rows, empty_context=None):
    if rows:
        context = {field: rows[0][field] for field in header if all((same_scalar(row[field], rows[0][field]) for row in rows))}
    else:
        context = dict(empty_context or {})
        require(set(context) <= set(header), 'EMPTY_CONTEXT_NOT_IN_HEADER')
    columns = [field for field in header if field not in context]
    return {'context': context, 'columns': columns, 'rows': [[row[field] for field in columns] for row in rows]}
