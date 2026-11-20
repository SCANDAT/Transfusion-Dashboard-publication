"""Validate the identity, dimensions and arithmetic of whitened CR2 summaries."""
from __future__ import annotations
import csv, hashlib, io, json, math, re, stat
from pathlib import Path
import numpy as np
from exact_numeric import decode_number, numeric_encoding
from cr2_white_archive_schema import CONTEXT, CONTEXT_CHARS, CONTEXT_NUMS, PROTOCOL, schemas
from cr2_joint_math import symmetric_square
from probability_functions import ibeta
from decimal_verification import DecimalReplayUnavailable
from mapping_check import check_scalar_weight_mapping
import scalar_availability as availability
VALIDATION_PROTOCOL = 'RBC_CR2_GLS_WHITE_VALIDATION_V2'
MAX_FILE_BYTES = 256 * 2 ** 20
MAX_TOTAL_BYTES = 2 ** 31
REQUIRED_EXPECTED = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId JobID Model FactorName VitalCode'.split())
FACTOR_LEVELS = {'NONE': (1,), 'DonorHb_Cat': (1, 2, 3, 4, 5), 'Storage_Cat': (1, 2, 3, 4, 5), 'DonorSex': (1, 2), 'DonorParity_Female': (0, 1), 'wdy_donation': (1, 2, 3, 4, 5, 6, 7)}
SCOPE_PAIRS = {'synthetic': 'SYNTHETIC_DATA_ONLY', 'development_sample': 'LOCAL_SAMPLE_MODEL_INFERENCE', 'full_cohort': 'FULL_COHORT_MODEL_INFERENCE'}
MANIFEST_CHARS = tuple('Protocol Role FileName NumericFormat TextEncoding ExportStatus'.split())
MANIFEST_NUMS = ('RowCount', 'ColumnCount')
TOKEN = re.compile('[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}')
NUMBER = re.compile('[+-]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[Ee][+-]?[0-9]+)?')
CERTIFICATE_REPLAY_FIELDS = ('ScalarFallbackContractions', 'ScalarFallbackMethod', 'ScalarFallbackPrecision', 'ScalarFallbackMode', 'ZeroScalarTargets', 'ScalarContractions', 'JointContractions')

class Reject(Exception):

    def __init__(self, code):
        self.code = code

def need(value, code='NUMERICAL_RECONSTRUCTION_REJECTED'):
    if not value:
        raise Reject(code)

def integer(x, code='DIMENSIONS_REJECTED'):
    need(np.isfinite(x) and abs(x) <= 2 ** 53 - 1 and (x == round(x)), code)
    return int(x)

def close(a, b, rtol=2e-07, atol=1e-10):
    need(bool(np.allclose(a, b, rtol=rtol, atol=atol, equal_nan=False)))

def parse_number(s):
    try:
        return decode_number(s, allow_legacy=True, allow_missing=True)
    except ValueError:
        raise Reject('CSV_NUMERIC_REJECTED') from None

def ancestors(path):
    path = Path(path).absolute()
    for item in (path, *path.parents):
        x = item.lstat()
        need(not stat.S_ISLNK(x.st_mode) and (not getattr(x, 'st_file_attributes', 0) & 1024), 'REPARSE_PATH_REJECTED')

def state(path):
    ancestors(path)
    x = path.lstat()
    need(stat.S_ISREG(x.st_mode) and (not path.is_symlink()) and (not getattr(x, 'st_file_attributes', 0) & 1024), 'FILE_TYPE_REJECTED')
    need(0 < x.st_size <= MAX_FILE_BYTES, 'FILE_SIZE_REJECTED')
    return (x.st_size, x.st_mtime_ns, x.st_dev, x.st_ino)

def directory(path):
    ancestors(path)
    x = path.lstat()
    need(stat.S_ISDIR(x.st_mode) and (not path.is_symlink()) and (not getattr(x, 'st_file_attributes', 0) & 1024), 'DIRECTORY_REJECTED')

class Table:

    def __init__(self, chars, nums, cr, nr):
        self.chars = chars
        self.nums = nums
        self.c = cr
        self.a = np.asarray(nr, dtype=float).reshape(len(nr), len(nums))
        self.ix = {k: i for i, k in enumerate(nums)}
        self.n = len(nr)

    def num(self, name):
        return self.a[:, self.ix[name]]

    def char(self, name):
        return [x[name] for x in self.c]

    def row(self, i=0):
        return {**self.c[i], **{k: self.a[i, j] for j, k in enumerate(self.nums)}}

class Intake:

    def __init__(self, folder, prefix, expected_files, started):
        self.folder = Path(folder)
        directory(self.folder)
        self.prefix = prefix
        self.expected_files = expected_files
        self.started = started
        self.before = {}
        self.hashes = {}
        self.total = 0
        self.numeric_encodings = set()

    def load(self, role, chars, nums, count=None, identity=None):
        fields = tuple(CONTEXT) + tuple(chars) + tuple(nums)
        need(len(set(fields)) == len(fields), 'SCHEMA_REJECTED')
        name = self.prefix + '_' + role + '.csv'
        path = self.folder / name
        before = state(path)
        if self.started is not None:
            need(before[1] >= self.started, 'STALE_EXPORT_REJECTED')
        raw = path.read_bytes()
        need(state(path) == before and len(raw) == before[0], 'FILE_CHANGED_REJECTED')
        digest = hashlib.sha256(raw).hexdigest()
        self.total += len(raw)
        need(self.total <= MAX_TOTAL_BYTES, 'ARCHIVE_SIZE_REJECTED')
        need(role not in self.before, 'DUPLICATE_ROLE_REJECTED')
        self.before[role] = before
        self.hashes[name] = {'sha256': digest, 'size_bytes': len(raw)}
        if self.expected_files is not None:
            need(self.expected_files.get(name) == self.hashes[name], 'CONTENT_HASH_REJECTED')
        need(b'\x00' not in raw, 'CSV_TEXT_REJECTED')
        stream = io.TextIOWrapper(io.BytesIO(raw), encoding='utf-8-sig', errors='strict', newline='')
        reader = csv.reader(stream, strict=True)
        header = next(reader)
        folded = [x.casefold() for x in header]
        mapping = {x.casefold(): x for x in fields}
        need(len(folded) == len(fields) and len(set(folded)) == len(fields) and (set(folded) == set(mapping)), 'SCHEMA_REJECTED')
        names = [mapping[x] for x in folded]
        ix = {x: i for i, x in enumerate(names)}
        cr = []
        nr = []
        for row in reader:
            need(len(row) == len(names) and all((len(x) <= 256 for x in row)), 'CSV_ROW_REJECTED')
            for key in (*CONTEXT_NUMS, *nums):
                try:
                    encoding = numeric_encoding(row[ix[key]])
                except ValueError:
                    raise Reject('CSV_NUMERIC_REJECTED') from None
                if encoding is not None:
                    self.numeric_encodings.add(encoding)
            contexts = {k: row[ix[k]] for k in CONTEXT_CHARS}
            contextn = {k: parse_number(row[ix[k]]) for k in CONTEXT_NUMS}
            if identity is not None:
                need(all((contexts[k] == identity[k] for k in CONTEXT_CHARS)) and all((contextn[k] == identity[k] for k in CONTEXT_NUMS)), 'CONTEXT_REJECTED')
            cr.append({k: row[ix[k]] for k in chars})
            nr.append([parse_number(row[ix[k]]) for k in nums])
            if role == 'identity':
                cr[-1].update(contexts)
                cr[-1].update(contextn)
            if count is not None:
                need(len(nr) <= count, 'ROW_COUNT_REJECTED')
            else:
                need(len(nr) <= 100, 'ROW_COUNT_REJECTED')
        if count is not None:
            need(len(nr) == count, 'ROW_COUNT_REJECTED')
        return Table(tuple(chars), tuple(nums), cr, nr)

    def finish(self):
        names = {self.prefix + '_' + role + '.csv' for role in self.before}
        need({x.name for x in self.folder.iterdir()} == names, 'UNEXPECTED_FILE_REJECTED')
        if self.expected_files is not None:
            need(set(self.expected_files) == names, 'CONTENT_HASH_REJECTED')
        manifest_time = self.before['archive_manifest'][1]
        for role, before in self.before.items():
            path = self.folder / (self.prefix + '_' + role + '.csv')
            need(before[1] <= manifest_time, 'MANIFEST_FRESHNESS_REJECTED')
            need(state(path) == before, 'FILE_CHANGED_REJECTED')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            need(state(path) == before and digest == self.hashes[path.name]['sha256'], 'FILE_CHANGED_REJECTED')
        content = hashlib.sha256(json.dumps(self.hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        return content

def dense(table, nr, nc):
    need(table.n == nr, 'MATRIX_SHAPE_REJECTED')
    a = table.a
    need(a.shape == (nr, nc) and np.isfinite(a).all(), 'MATRIX_SHAPE_REJECTED')
    return a

def long_matrix(table, nr, nc, row='Row', col='Col', value='Value'):
    a = np.full((nr, nc), np.nan)
    for x in table.a:
        rr = integer(x[table.ix[row]], 'MATRIX_INDEX_REJECTED') - 1
        cc = integer(x[table.ix[col]], 'MATRIX_INDEX_REJECTED') - 1
        need(0 <= rr < nr and 0 <= cc < nc and np.isnan(a[rr, cc]), 'MATRIX_INDEX_REJECTED')
        a[rr, cc] = x[table.ix[value]]
    need(np.isfinite(a).all(), 'MATRIX_SHAPE_REJECTED')
    return a

def symmetry(a, psd=False, pd=False, envelope=0.0):
    scale = max(np.linalg.norm(a), np.finfo(float).tiny)
    need(np.linalg.norm(a - a.T) <= 2e-08 * scale, 'MATRIX_SYMMETRY_REJECTED')
    if psd or pd:
        w = np.linalg.eigvalsh((a + a.T) / 2)
        need(w[-1] > 0, 'MATRIX_PSD_REJECTED')
        if pd:
            need(w[0] > 1e-12 * w[-1], 'MATRIX_PD_REJECTED')
        else:
            need(w[0] >= -max(envelope, 2e-08 * w[-1]), 'MATRIX_PSD_REJECTED')

def covariance_close(a, b):
    need(np.diag(b).min() >= -1e-10 * max(np.diag(b).max(), np.finfo(float).tiny), 'COVARIANCE_REJECTED')
    d = np.sqrt(np.maximum(np.diag(b), 0))
    need(np.all(np.abs(a - b) <= 1e-10 + 2e-06 * np.outer(d, d)) and np.linalg.norm(a - b) <= 2e-07 * max(np.linalg.norm(b), np.finfo(float).tiny), 'COVARIANCE_RECONSTRUCTION_REJECTED')

def row_inverse(a):
    u, s, v = np.linalg.svd(a, full_matrices=False)
    need(s[-1] > 1e-06 * s[0], 'SPAN_RANK_REJECTED')
    return v.T / s @ u.T

def t_probability(t, df):
    return ibeta(df / 2, 0.5, df / (df + t * t))

def t_critical(df, alpha):
    lo = 0.0
    hi = 2.0
    for _ in range(40):
        if t_probability(hi, df) <= alpha:
            break
        hi *= 2
    else:
        raise Reject('DISTRIBUTION_REJECTED')
    for _ in range(65):
        mid = (lo + hi) / 2
        if t_probability(mid, df) > alpha:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2

def check_identity(identity, expected, prefix, scalar_policy=availability.STRICT):
    need(isinstance(expected, dict) and set(REQUIRED_EXPECTED) <= set(expected), 'EXPECTED_CONTEXT_REQUIRED')
    need(all((isinstance(expected[k], str) and TOKEN.fullmatch(expected[k]) for k in REQUIRED_EXPECTED)), 'EXPECTED_CONTEXT_REJECTED')
    need(expected['CohortMode'] in SCOPE_PAIRS and expected['Model'] in ('BASE', 'FULL') and (expected['FactorName'] in FACTOR_LEVELS) and (expected['VitalCode'] in ('ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE')), 'EXPECTED_CONTEXT_REJECTED')
    need(bool(re.fullmatch('[0-9a-f]{32}', expected['RunId'])) and all((re.fullmatch('[0-9a-f]{64}', expected[k]) for k in ('CodeHash', 'ConfigHash'))), 'EXPECTED_CONTEXT_REJECTED')
    required = {k: expected[k] for k in REQUIRED_EXPECTED if k in CONTEXT}
    required.update(Scope=SCOPE_PAIRS[expected['CohortMode']], BindingVersion=3.0, TargetCalibrationVerified=1.0, AllCoefficientsCalibrated=0.0, CalibrationDomain='FIXED_PREDECLARED_TARGET_SPAN', StructuralCertificate='RAW_LITERAL_SUPPORT_V1', WorkingBindingVersion=1.0, CR2ArchiveID=prefix, InferenceStatus='CR2_CHECKS_PASSED', WorkingInferenceStatus='MODEL_BASED_CANDIDATE', DFMethod='SATTERTHWAITE', WorkingDFMethod='RESIDUAL', CovarianceMethod='GLS_WHITENED_CR2', ScalarDFMethod='CONTRAST_SATTERTHWAITE', JointDFMethod='HTZ', WorkingTarget='FROZEN_REML_RANDOM_INTERCEPT_IID', CR2Protocol=availability.cr2_protocol(scalar_policy), SubjectAlias='PatientID', SubjectKeySource='SYNTHETIC_PERSON' if expected['CohortMode'] == 'synthetic' else 'PersonKey', DesignIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH', ProfileIdentityKind='ASSIGNED_ID_NOT_CONTENT_HASH')
    need(all((identity.get(k) == v for k, v in required.items())), 'IDENTITY_REJECTED')
    need(all((identity[k] == expected[k] for k in expected if k in CONTEXT)), 'IDENTITY_REJECTED')
    need(all((isinstance(identity[k], str) and identity[k] for k in CONTEXT_CHARS)), 'IDENTITY_REJECTED')

def check_plan(tables, expected, k, planned):
    family = tables['family_plan'].row()
    levels = FACTOR_LEVELS[expected['FactorName']]
    need(planned == len(levels) and 1 <= k <= planned, 'FAMILY_REJECTED')
    need(all((family[x] == expected[x] for x in ('Model', 'FactorName', 'VitalCode'))), 'FAMILY_REJECTED')
    fid = expected['FitId'] + '.PAIRWISE'
    role = 'PRIMARY' if expected['PopulationId'] == 'PRIMARY' and expected['Model'] == 'FULL' else 'SECONDARY'
    need(all((family[x] == y for x, y in {'FamilyID': fid, 'FamilyRole': role, 'FreezeStage': 'PRE_FIT', 'PlanVersion': 1.0, 'PlannedPairs': planned * (planned - 1) / 2, 'ActivePairs': k * (k - 1) / 2, 'PAdjustment': 'Holm within family', 'CIAdjustment': 'None: pointwise'}.items())), 'FAMILY_REJECTED')
    available = {}
    seen = set()
    for j in range(tables['cat_availability'].n):
        row = tables['cat_availability'].row(j)
        code = integer(row['CategoryCode'], 'FAMILY_REJECTED')
        need(code in levels and code not in seen and (row['Available'] in (0, 1)), 'FAMILY_REJECTED')
        seen.add(code)
        if row['Available'] == 1:
            index = integer(row['CategoryIndex'], 'FAMILY_REJECTED')
            need(row['AvailabilityReason'] == 'AVAILABLE' and index not in available, 'FAMILY_REJECTED')
            available[index] = code
        else:
            need(np.isnan(row['CategoryIndex']) and row['AvailabilityReason'] in ('ABSENT_IN_SCOPE', 'LOST_AT_COMPLETE_CASE'), 'FAMILY_REJECTED')
    need(seen == set(levels) and set(available) == set(range(1, k + 1)), 'FAMILY_REJECTED')
    need(list((available[i] for i in range(1, k + 1))) == sorted(available.values()), 'FAMILY_REJECTED')
    inverse = {code: index for index, code in available.items()}
    plan = {}
    expected_ids = {f'W_{a}' for a in levels} | {f'P_{a}_{b}' for a in levels for b in levels if a < b}
    for j in range(tables['contrast_plan'].n):
        row = tables['contrast_plan'].row(j)
        name = row['ContrastID']
        need(name in expected_ids and name not in plan, 'FAMILY_REJECTED')
        plan[name] = row
        a = integer(row['CategoryCodeA'], 'FAMILY_REJECTED')
        pair = row['ContrastType'] == 'PAIRWISE'
        need(row['ContrastType'] in ('PAIRWISE', 'WITHIN') and row['Planned'] == 1 and (row['BeforeMinute'] == -60) and (row['AfterMinute'] == 60), 'FAMILY_REJECTED')
        if pair:
            b = integer(row['CategoryCodeB'], 'FAMILY_REJECTED')
            need(a < b and a in levels and (b in levels) and (name == f'P_{a}_{b}') and (row['FamilyID'] == fid), 'FAMILY_REJECTED')
        else:
            b = None
            need(name == f'W_{a}' and a in levels and np.isnan(row['CategoryCodeB']) and np.isnan(row['CategoryIndexB']) and (row['FamilyID'] == 'NONE'), 'FAMILY_REJECTED')
        active = a in inverse and (not pair or b in inverse)
        need(row['Active'] == int(active) and row['ExclusionReason'] == ('NONE' if active else 'CATEGORY_UNAVAILABLE'), 'FAMILY_REJECTED')
        for code, key in [(a, 'CategoryIndexA')] + ([(b, 'CategoryIndexB')] if pair else []):
            need(row[key] == inverse[code] if code in inverse else np.isnan(row[key]), 'FAMILY_REJECTED')
    need(set(plan) == expected_ids, 'FAMILY_REJECTED')
    return ([available[i] for i in range(1, k + 1)], fid)

def _validate(folder, prefix, expected_context, expected_files=None, export_started_ns=None, decimal_replay=None):
    need(isinstance(prefix, str) and bool(re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,8}', prefix)), 'PREFIX_REJECTED')
    need(export_started_ns is None or (type(export_started_ns) is int and export_started_ns > 0), 'EXPECTED_TIME_REJECTED')
    need(expected_files is None or isinstance(expected_files, dict), 'EXPECTED_HASHES_REJECTED')
    if isinstance(expected_context, dict) and expected_context.get('CohortMode') in ('development_sample', 'full_cohort'):
        need(expected_files is not None or export_started_ns is not None, 'TRUSTED_FRESHNESS_OR_HASHES_REQUIRED')
    intake = Intake(folder, prefix, expected_files, export_started_ns)
    try:
        scalar_policy = availability.policy(expected_context.get(availability.CONFIG_KEY) if isinstance(expected_context, dict) else None)
    except availability.AvailabilityRejected:
        raise Reject('EXPECTED_CONTEXT_REJECTED') from None
    candidate = scalar_policy == availability.LCPU_V1
    identity = intake.load('identity', (), (), 1).row()
    check_identity(identity, expected_context, prefix, scalar_policy)
    base = schemas(8, 8, 7, 1)
    tables = {}
    for role in ('si_context', 'family_plan', 'status', 'working_target'):
        ch, nu, _ = base[role]
        tables[role] = intake.load(role, ch, nu, 1, identity)
    context = tables['si_context'].row()
    family = tables['family_plan'].row()
    working = tables['working_target'].row()
    p = integer(context['ParameterCount'])
    rank = integer(context['DesignRank'])
    h = integer(context['SpanDimension'])
    d = integer(context['MomentDimension'])
    G = integer(context['ClusterCount'])
    k = integer(family['AvailableCategories'])
    planned = integer(family['PlannedCategories'])
    need(1 <= p <= 500 and G >= 2 and (d == h * (h + 1) // 2) and (1 <= h <= rank <= p) and (1 <= k <= planned <= 7), 'DIMENSIONS_REJECTED')
    schema = schemas(p, rank, h, k, scalar_policy=scalar_policy)
    need(context['StatisticKind'] == 'AUGMENTED_QR', 'WORKING_TARGET_REJECTED')
    certified = integer(context['CertifiedClusters'])
    nullity = integer(context['MaxCertifiedNullity'])
    need(0 <= certified <= G and 0 <= nullity <= rank and ((certified == 0) == (nullity == 0)), 'STRUCTURAL_CERTIFICATE_REJECTED')
    tau = context['Tau2']
    sigma = context['Sigma2']
    alpha = context['Alpha']
    envelope = context['RoundoffEnvelope']
    need(np.isfinite([tau, sigma, alpha, envelope]).all() and tau >= 0 and (sigma > 0) and (0 < alpha < 1) and (envelope > 0), 'WORKING_TARGET_REJECTED')
    need(alpha == expected_context.get('Alpha', 0.05) and all((working[x] == context[x] for x in ('Tau2', 'Sigma2', 'Alpha'))) and (working['ComponentCount'] == 2) and (working['RIComponents'] == 1) and (working['ResidualComponents'] == 1), 'WORKING_TARGET_REJECTED')
    need(tables['status'].row()['IntegrationStatus'] == 'CR2_CHECKS_PASSED' and tables['status'].row()['ReasonCode'] == 'PASS', 'INTEGRATION_STATUS_REJECTED')
    manifest = intake.load('archive_manifest', MANIFEST_CHARS, MANIFEST_NUMS, len(schema), identity)
    manifest_by = {}
    for j in range(manifest.n):
        row = manifest.row(j)
        role = row['Role']
        need(role in schema and role not in manifest_by, 'MANIFEST_REJECTED')
        manifest_by[role] = row
        need(row['Protocol'] == PROTOCOL and row['FileName'] == prefix + '_' + role + '.csv' and (row['NumericFormat'] in {'E32_STDIEEE', 'HEX16_IEEE754'}) and (row['TextEncoding'] == 'UTF-8') and (row['ExportStatus'] == 'EXPORTED_LOCAL_ONLY'), 'MANIFEST_REJECTED')
    need(set(manifest_by) == set(schema), 'MANIFEST_REJECTED')
    formats = {row['NumericFormat'] for row in manifest_by.values()}
    need(len(formats) == 1, 'MANIFEST_REJECTED')
    numeric_format = next(iter(formats))
    allowed = {prefix + '_' + role + '.csv' for role in (*schema, 'archive_manifest')}
    need({x.name for x in intake.folder.iterdir()} == allowed, 'UNEXPECTED_FILE_REJECTED')
    if expected_files is not None:
        need(set(expected_files) == allowed, 'CONTENT_HASH_REJECTED')
    manifest_time = intake.before['archive_manifest'][1]
    need(all((state(intake.folder / name)[1] <= manifest_time for name in allowed)), 'MANIFEST_FRESHNESS_REJECTED')
    for role, (ch, nu, count) in schema.items():
        if role == 'cat_availability':
            count = planned
        if role == 'contrast_plan':
            count = planned + planned * (planned - 1) // 2
        if role == availability.ROLE:
            count = integer(manifest_by[role]['RowCount'], 'MANIFEST_REJECTED')
            need(0 <= count <= 2 * 1441 * k, 'MANIFEST_REJECTED')
        need(manifest_by[role]['RowCount'] == count and manifest_by[role]['ColumnCount'] == len(CONTEXT) + len(ch) + len(nu), 'MANIFEST_REJECTED')
        if role == 'identity':
            continue
        if role not in tables:
            tables[role] = intake.load(role, ch, nu, count, identity)
    need(intake.numeric_encodings <= {numeric_format}, 'NUMERIC_ENCODING_REJECTED')
    codes, fid = check_plan(tables, expected_context, k, planned)
    covariance = long_matrix(tables['si_covariance'], p, p)
    E = long_matrix(tables['si_basis'], p, rank, 'Parameter', 'ActiveColumn')
    B = long_matrix(tables['si_bread'], rank, rank)
    beta = long_matrix(Table((), ('Row', 'Col', 'Value'), [], np.column_stack([tables['si_solution'].num('Parameter'), np.ones(p), tables['si_solution'].num('Estimate')])), p, 1).ravel()
    CB = dense(tables['si_spanbasis'], h, p)
    VR = dense(tables['si_spanrobust'], h, h)
    M = dense(tables['si_moment'], d, d)
    close(E.T @ E, np.eye(rank), rtol=0, atol=2e-09)
    symmetry(B, pd=True)
    symmetry(covariance, psd=True)
    symmetry(VR, psd=True)
    close(CB, CB @ E @ E.T, rtol=2e-08, atol=1e-09)
    close(CB @ E @ B @ (CB @ E).T, np.eye(h), rtol=2e-08, atol=1e-09)
    covariance_close(covariance, E @ (E.T @ covariance @ E) @ E.T)
    covariance_close(VR, CB @ covariance @ CB.T)
    need(np.linalg.norm(M - M.T) <= 2e-10 * np.linalg.norm(M), 'MOMENT_SYMMETRY_REJECTED')
    mw = np.linalg.eigvalsh((M + M.T) / 2)
    need(mw[-1] > 0 and mw[0] >= -envelope - 128 * np.finfo(float).eps * mw[-1], 'MOMENT_PSD_REJECTED')
    need(envelope >= np.finfo(float).eps * (64 + 8 * G) * np.linalg.norm(M) * (1 - 2e-08), 'MOMENT_ENVELOPE_REJECTED')
    from certificate_intake import intake_certificate
    try:
        tables['_certificate'] = intake_certificate(tables, identity, expected_context, h=h, k=k, moment=M, numeric_format=numeric_format, decimal_replay=decimal_replay)
    except (ValueError, ArithmeticError, FloatingPointError):
        raise Reject('CERTIFICATE_REPLAY_REJECTED') from None
    CBplus = row_inverse(CB)
    _check_targets(tables, codes, fid, beta, CB, CBplus, VR, M, envelope, G, alpha, scalar_policy)
    _check_joint(tables, codes, beta, CB, CBplus, VR, M, envelope)
    digest = intake.finish()
    replay = {k: tables['_certificate']['Report'].get(k) for k in CERTIFICATE_REPLAY_FIELDS}
    scope = 'CERTIFIED_SCORE_SPAN_IDENTITY_NATIVE_WEIGHT_CONTRACTION_REPLAY_ALL_SCALARS_COVARIANCE_HTZ_HOLM'
    if candidate:
        scope = 'CERTIFIED_SCORE_SPAN_IDENTITY_NATIVE_WEIGHT_CONTRACTION_REPLAY_COMPUTED_SCALARS_LC_UNCERTAINTY_UNAVAILABLE_POINTS_COVARIANCE_HTZ_HOLM'
    result = {'status': 'VALIDATED', 'protocol': VALIDATION_PROTOCOL, 'reason_code': 'PASS', 'ArchiveContentDigest': digest, 'ExpectedFiles': intake.hashes, 'ValidationScope': scope, 'ConstructionProofReplayed': False, 'CertificateReplay': replay, 'FullRunReady': False}
    if candidate:
        result['ScalarAvailability'] = tables['_availability']
    return result

def _check_targets(tables, codes, fid, beta, CB, CBplus, VR, M, envelope, G, alpha, scalar_policy=availability.STRICT):
    candidate = availability.policy(scalar_policy) == availability.LCPU_V1
    k = len(codes)
    p = len(beta)
    N = 1441 * k
    pairs = [(a, b) for a in range(k) for b in range(a + 1, k)]
    q = 2 * N + k + len(pairs)
    design = tables['target_design']
    need(np.array_equal(design.num('TargetIndex'), np.arange(1, q + 1)), 'TARGET_INDEX_REJECTED')
    C = design.a[:, 1:]
    need(C.shape == (q, p) and np.isfinite(C).all(), 'TARGET_DESIGN_REJECTED')
    score = C[:N].copy()
    change = score.copy()
    within = []
    for a in range(k):
        change[a * 1441:(a + 1) * 1441] -= score[a * 1441 + 660]
        within.append(score[a * 1441 + 780] - score[a * 1441 + 660])
    within = np.asarray(within)
    paired = np.asarray([within[a] - within[b] for a, b in pairs]).reshape(len(pairs), p)
    reconstructed = np.vstack([score, change, within, paired])
    close(C, reconstructed, rtol=2e-10, atol=1e-12)
    expected_keys = np.full((q, 8), np.nan)
    expected_keys[:, 0] = np.arange(1, q + 1)
    for block, kind in ((0, 1), (N, 2)):
        sl = slice(block, block + N)
        expected_keys[sl, 1] = kind
        expected_keys[sl, 2] = np.arange(1, N + 1)
        expected_keys[sl, 3] = np.repeat(np.arange(1, k + 1), 1441)
        expected_keys[sl, 5] = np.tile(np.arange(-720, 721), k)
        expected_keys[sl, 6] = np.repeat(codes, 1441)
    for a in range(k):
        expected_keys[2 * N + a] = [2 * N + a + 1, 3, np.nan, a + 1, np.nan, 60, codes[a], np.nan]
    for j, (a, b) in enumerate(pairs):
        expected_keys[2 * N + k + j] = [2 * N + k + j + 1, 4, np.nan, a + 1, b + 1, 60, codes[a], codes[b]]
    keycols = ('TargetIndex', 'TargetKind', 'GridID', 'CategoryIndexA', 'CategoryIndexB', 'TimeFromTransfusion', 'CategoryCodeA', 'CategoryCodeB')
    actual_keys = np.column_stack([tables['target_keys'].num(x) for x in keycols])
    need(np.array_equal(actual_keys, expected_keys, equal_nan=True), 'TARGET_KEYS_REJECTED')
    reconstructed_weights = C @ CBplus
    certificate = tables['_certificate']
    weights = np.vstack([certificate['ScalarWeights'][i] for i in range(1, q + 1)])
    check_scalar_weight_mapping(weights, reconstructed_weights, need)
    error = np.linalg.norm(C - weights @ CB, axis=1)
    norm = np.linalg.norm(C, axis=1)
    need(np.all(error <= 2e-08 * norm), 'TARGET_OUTSIDE_SPAN_REJECTED')
    estimate = C @ beta
    zero = np.zeros(q, dtype=bool)
    for a in range(k):
        zero[N + a * 1441 + 660] = True
    need(np.array_equal(norm == 0, zero), 'BASELINE_DESIGN_REJECTED')
    observed = [None] * q
    for role, kind in [('levels', 1), ('changes', 2), ('within', 3), ('pairwise', 4)]:
        table = tables[role]
        for j in range(table.n):
            row = table.row(j)
            index = integer(row['TargetIndex'], 'TARGET_INDEX_REJECTED') - 1
            need(0 <= index < q and observed[index] is None and (row['TargetKind'] == kind), 'TARGET_INDEX_REJECTED')
            observed[index] = row
    need(all((x is not None for x in observed)), 'TARGET_COMPLETENESS_REJECTED')
    unavailable = np.zeros(q, dtype=bool)
    for index, row in enumerate(observed):
        need(np.array_equal(np.array([row[x] for x in keycols]), expected_keys[index], equal_nan=True), 'TARGET_KEYS_REJECTED')
        kind = int(row['TargetKind'])
        role = ('LEVEL', 'CHANGE', 'WITHIN', 'PAIRWISE')[kind - 1]
        if kind in (1, 2):
            name = ('L_' if kind == 1 else 'C_') + f"{int(row['GridID']):08d}"
        elif kind == 3:
            name = f"W_{int(row['CategoryCodeA'])}"
        else:
            name = f"P_{int(row['CategoryCodeA'])}_{int(row['CategoryCodeB'])}"
        need(row['TargetID'] == name and row['TargetRole'] == role and (row['BaselineMinute'] == -60) and (row['EndpointMinute'] == 60), 'TARGET_LABEL_REJECTED')
        need(row['FamilyID'] == (fid if kind == 4 else 'NONE') and row['PAdjustment'] == ('Holm within frozen family' if kind == 4 else 'NONE'), 'TARGET_FAMILY_REJECTED')
        need(row['CIAdjustment'] == ('Deterministic zero' if zero[index] else 'None: pointwise'), 'TARGET_LABEL_REJECTED')
        if zero[index]:
            need(row['ContrastStatus'] == 2 and row['NumericStatus'] == 'BASELINE_ZERO' and all((row[x] == 0 for x in ('Estimate', 'StdErr', 'Lower', 'Upper', 'Variance', 'ReferenceVariance'))) and all((np.isnan(row[x]) for x in ('DF', 'tValue', 'Probt'))), 'BASELINE_ZERO_REJECTED')
        elif candidate and kind in availability.ELIGIBLE_KINDS and (row['ContrastStatus'] == availability.NATIVE_UNRESOLVED_STATUS):
            need(row['NumericStatus'] == availability.UNAVAILABLE_REASON and bool(np.isfinite(row['Estimate'])) and all((np.isnan(row[x]) for x in availability.UNCERTAINTY_FIELDS)), 'SCALAR_UNAVAILABLE_ROW_REJECTED')
            unavailable[index] = True
        else:
            need(row['ContrastStatus'] == 0 and row['NumericStatus'] == 'COMPUTED', 'ACTIVE_SCALAR_STATUS_REJECTED')
    ii, jj = np.triu_indices(len(CB))
    multipliers = np.sqrt(2 - (ii == jj).astype(int))
    valid = np.flatnonzero(~zero & ~unavailable)
    for start in range(0, len(valid), 128):
        indices = valid[start:start + 128]
        w = weights[indices]
        v = w[:, ii] * w[:, jj] * multipliers
        denominator = np.einsum('ni,ni->n', v, v @ M)
        reference = np.einsum('ni,ni->n', w, w)
        variance = np.einsum('ni,ni->n', w, w @ VR)
        native = np.array([certificate['Scalars'][int(i) + 1]['Denominator'] for i in indices], dtype=float)
        need(all((certificate['Scalars'][int(i) + 1]['Resolved'] == 1 for i in indices)), 'SCALAR_MOMENT_SUPPORT_REJECTED')
        close(denominator, native, rtol=2e-07, atol=0.0)
        denominator = native
        need(np.isfinite(denominator).all() and np.all(denominator > 0), 'SCALAR_MOMENT_SUPPORT_REJECTED')
        df = reference ** 2 / denominator
        need(np.all(variance > 0) and np.all(reference > 0) and np.all(df >= 1 - 1e-08) and np.all(df <= G * (1 + 1e-08)), 'SCALAR_VARIANCE_DF_REJECTED')
        for j, index in enumerate(indices):
            row = observed[index]
            mu = estimate[index]
            se = math.sqrt(variance[j])
            dof = df[j]
            t = mu / se
            pv = t_probability(t, dof)
            critical = t_critical(dof, alpha)
            close([row[x] for x in ('Estimate', 'StdErr', 'DF', 'tValue', 'Variance', 'ReferenceVariance')], [mu, se, dof, t, variance[j], reference[j]], rtol=2e-07, atol=1e-09)
            need(0 <= row['Probt'] <= 1, 'SCALAR_PROBABILITY_REJECTED')
            close(row['Probt'], pv, rtol=2e-07, atol=1e-10)
            close([row['Lower'], row['Upper']], [mu - critical * se, mu + critical * se], rtol=2e-07, atol=2e-09 * max(abs(mu), critical * se, 1e-06))
    if candidate:
        tables['_availability'] = _check_unavailable(tables, observed, unavailable, weights, estimate, VR, N, k, q)
    family = [observed[i] for i in range(2 * N + k, q)]
    need(all((row['ContrastStatus'] == 0 and row['NumericStatus'] == 'COMPUTED' for row in family)), 'HOLM_INPUT_REJECTED')
    try:
        adjusted = availability.holm_adjusted([row['Probt'] for row in family], len(pairs), [row['TargetIndex'] for row in family])
    except availability.AvailabilityRejected:
        raise Reject('HOLM_INPUT_REJECTED') from None
    holm = {row['TargetIndex']: value for row, value in zip(family, adjusted)}
    pp = sorted(family, key=lambda x: (x['Probt'], x['TargetIndex']))
    for rank, row in enumerate(pp, 1):
        need(row['Rank'] == rank and row['PValue'] == row['Probt'], 'HOLM_FAMILY_REJECTED')
        close(row['PValue_Holm'], holm[row['TargetIndex']], rtol=1e-12, atol=1e-15)
    tables['_score'] = score
    tables['_within'] = within

def _same_bits(a, b):
    return isinstance(a, float) and isinstance(b, float) and math.isfinite(a) and math.isfinite(b) and (float(a).hex() == float(b).hex())

def _check_unavailable(tables, observed, unavailable, weights, estimate, VR, N, k, q):
    """LCPU_V1: independently establish every uncertainty-unavailable LEVEL/CHANGE row.

    Never trusts a label: the native certificate class is re-derived from the
    NATIVE centre/radius under the unchanged rule; the native radius was already
    required to dominate the independent fast or directed-Decimal replay for
    EVERY nonzero row (intake_certificate); mapping/span were checked for all rows.
    """
    certificate = tables['_certificate']
    report = certificate['Report']
    indices = [int(i) for i in np.flatnonzero(unavailable)]
    need(report.get('ScalarContractions', -1) + report.get('ZeroScalarTargets', -1) == q, 'CERTIFICATE_REPLAY_INCOMPLETE')
    entries = []
    for index in indices:
        row = observed[index]
        cert = certificate['Scalars'][index + 1]
        cls = availability.classify_native_certificate(cert)
        need(cls == 'PRECISION_UNRESOLVED', 'SCALAR_UNAVAILABLE_' + cls)
        need(bool(np.allclose(row['Estimate'], estimate[index], rtol=2e-07, atol=1e-09, equal_nan=False)), 'SCALAR_UNAVAILABLE_POINT_REJECTED')
        w = weights[index]
        variance = float(w @ VR @ w)
        reference = float(w @ w)
        need(np.isfinite(variance) and np.isfinite(reference) and (variance > 0) and (reference > 0), 'SCALAR_UNAVAILABLE_GEOMETRY_REJECTED')
        entries.append(dict(TargetIndex=index + 1, TargetID=row['TargetID'], TargetRole=row['TargetRole'], TargetKind=int(row['TargetKind']), GridID=int(row['GridID']), NativeContrastStatus=int(row['ContrastStatus']), UnavailableReason=availability.UNAVAILABLE_REASON, **{m: float(cert[m]) for m in availability.CERTIFICATE_METRICS}))
    need(list(report.get('NativeUnresolvedScalarTargets', ())) == [i + 1 for i in indices], 'SCALAR_UNAVAILABLE_SET_REJECTED')
    _check_declared(tables[availability.ROLE], entries)
    for a in range(k):
        c, w = (N + a * 1441 + 780, 2 * N + a)
        change, within = (observed[c], observed[w])
        need(not unavailable[c] and change['ContrastStatus'] == within['ContrastStatus'] == 0 and (change['NumericStatus'] == within['NumericStatus'] == 'COMPUTED') and (certificate['Scalars'][c + 1]['Resolved'] == certificate['Scalars'][w + 1]['Resolved'] == 1), 'ENDPOINT_DUPLICATE_REJECTED')
        fields = ('Estimate',) + availability.UNCERTAINTY_FIELDS
        need(bool(np.allclose([change[x] for x in fields], [within[x] for x in fields], rtol=2e-07, atol=1e-09, equal_nan=False)), 'ENDPOINT_DUPLICATE_REJECTED')
    try:
        return availability.build_summary(entries, report)
    except availability.AvailabilityRejected as error:
        raise Reject(error.code) from None

def _check_declared(table, entries):
    """Declared scalar_unavailable rows == independently derived set, field by field,
    with bit-identical copies of the bound native certificate metrics."""
    by_index = {e['TargetIndex']: e for e in entries}
    need(table.n == len(entries), 'SCALAR_UNAVAILABLE_SET_REJECTED')
    seen = set()
    for j in range(table.n):
        row = table.row(j)
        index = integer(row['TargetIndex'], 'SCALAR_UNAVAILABLE_SET_REJECTED')
        need(index in by_index and index not in seen, 'SCALAR_UNAVAILABLE_SET_REJECTED')
        seen.add(index)
        e = by_index[index]
        need(row['TargetID'] == e['TargetID'] and row['TargetRole'] == e['TargetRole'] and (row['UnavailableReason'] == availability.UNAVAILABLE_REASON) and (row['TargetKind'] == e['TargetKind']) and (row['GridID'] == e['GridID']) and (row['NativeContrastStatus'] == e['NativeContrastStatus']), 'SCALAR_UNAVAILABLE_SET_REJECTED')
        need(all((_same_bits(float(row[m]), e[m]) for m in availability.CERTIFICATE_METRICS)), 'SCALAR_UNAVAILABLE_CERTIFICATE_BINDING_REJECTED')
    need(seen == set(by_index), 'SCALAR_UNAVAILABLE_SET_REJECTED')

def _check_joint(tables, codes, beta, CB, CBplus, VR, M, envelope):
    k = len(codes)
    score = tables['_score']
    within = tables['_within']
    betaNorm = CB @ beta
    jt = tables['joint']
    need(jt.n == 2 and set(jt.num('TestIndex')) == {1.0, 2.0}, 'JOINT_FAMILY_REJECTED')
    rows = {integer(jt.row(i)['TestIndex']): jt.row(i) for i in range(2)}
    for test in (1, 2):
        need(rows[test]['TestRole'] == ('ENDPOINT_HETEROGENEITY' if test == 1 else 'WHOLE_TRAJECTORY_INTERACTION'), 'JOINT_LABEL_REJECTED')
    if k == 1:
        for row in rows.values():
            need(row['JointStatus'] == 3 and row['Q'] == 0 and (row['NumericStatus'] == 'NOT_APPLICABLE_SINGLE_CATEGORY') and all((np.isnan(row[x]) for x in ('Nu', 'DF1', 'DF2', 'Wald', 'FValue', 'ProbF', 'MomentDenominator'))), 'JOINT_NOT_APPLICABLE_REJECTED')
        return
    endpoint = np.asarray([within[c] - within[0] for c in range(1, k)])
    anchor_times = (-660, -360, -60, 60, 360, 660)
    anchor_indices = (2, 3, 4, 6, 7, 8)
    whole = np.asarray([score[c * 1441 + t + 720] - score[c * 1441 + 720] - score[t + 720] + score[720] for c in range(1, k) for t in anchor_times])
    jd = tables['joint_design']
    need(jd.n == 7 * (k - 1), 'JOINT_FAMILY_REJECTED')
    for test, C in [(1, endpoint), (2, whole)]:
        q = len(C)
        ix = np.flatnonzero(jd.num('TestIndex') == test)
        need(len(ix) == q, 'JOINT_FAMILY_REJECTED')
        ix = ix[np.argsort(jd.num('ConstraintIndex')[ix])]
        need(np.array_equal(jd.num('ConstraintIndex')[ix], np.arange(1, q + 1)), 'JOINT_FAMILY_REJECTED')
        categories = np.arange(2, k + 1) if test == 1 else np.repeat(np.arange(2, k + 1), 6)
        need(np.array_equal(jd.num('CategoryIndex')[ix], categories), 'JOINT_FAMILY_REJECTED')
        anchors = np.full(q, np.nan) if test == 1 else np.tile(anchor_indices, k - 1)
        need(np.array_equal(jd.num('AnchorIndex')[ix], anchors, equal_nan=True), 'JOINT_FAMILY_REJECTED')
        close(jd.a[ix, 4:], C, rtol=2e-10, atol=1e-12)
        weights = C @ CBplus
        need(np.all(np.linalg.norm(C - weights @ CB, axis=1) <= 2e-08 * np.linalg.norm(C, axis=1)), 'JOINT_OUTSIDE_SPAN_REJECTED')
        scales = np.linalg.norm(weights, axis=1)
        need(np.all(scales > 0), 'JOINT_REDUNDANT_REJECTED')
        w = weights / scales[:, None]
        U, s, Vt = np.linalg.svd(w, full_matrices=False)
        need(s[-1] > 1e-06 * s[0], 'JOINT_REDUNDANT_REJECTED')
        normal = U / s @ U.T
        wn = normal @ w
        certificate = tables['_certificate']
        cert = certificate['Joints'][test]
        native = np.vstack([certificate['JointWeights'][test, i] for i in range(1, q + 1)])
        close(native @ native.T, np.eye(q), rtol=0, atol=2e-08)
        need(np.all(np.linalg.norm(w - w @ native.T @ native, axis=1) <= 2e-08 * np.linalg.norm(w, axis=1)), 'NATIVE_JOINT_TARGET_SPAN_REJECTED')
        close(wn @ native.T @ (wn @ native.T).T, np.eye(q), rtol=0, atol=2e-08)
        S = symmetric_square(native)
        reconstructed_denominator = 2 * float(np.sum(S * (S @ M)))
        denominator = cert['Denominator']
        row = rows[test]
        if cert['Resolved'] == 1:
            close(reconstructed_denominator, denominator, rtol=2e-06, atol=0.0)
        close([row[x] for x in ('Q', 'DF1', 'MomentDenominator')], [q, q, denominator], rtol=2e-06, atol=1e-09)
        if denominator > 0:
            nu = q * (q + 1) / denominator
            df2 = nu - q + 1
            close([row['Nu'], row['DF2']], [nu, df2], rtol=2e-06, atol=1e-09)
        else:
            need(np.isnan(row['Nu']) and np.isnan(row['DF2']), 'JOINT_UNSUPPORTED_CENTER_REJECTED')
        if cert['Resolved'] != 1:
            need(row['JointStatus'] == 4 and row['NumericStatus'] == 'MOMENT_PRECISION_UNRESOLVED' and all((np.isnan(row[x]) for x in ('Wald', 'FValue', 'ProbF'))), 'JOINT_UNSUPPORTED_CERTIFICATE_REJECTED')
            continue
        need(denominator > 0, 'JOINT_MOMENT_SUPPORT_REJECTED')
        observed = native @ VR @ native.T
        symmetry(observed, pd=True)
        theta = native @ betaNorm
        wald = float(theta @ np.linalg.solve(observed, theta))
        need(wald >= 0, 'JOINT_WALD_REJECTED')
        close(row['Wald'], wald, rtol=2e-06, atol=1e-09)
        independent_cov = wn @ VR @ wn.T
        symmetry(independent_cov, pd=True)
        independent_theta = normal @ (w @ betaNorm)
        independent_wald = float(independent_theta @ np.linalg.solve(independent_cov, independent_theta))
        close(wald, independent_wald, rtol=2e-06, atol=1e-09)
        if cert['DF2Sign'] in (0, 2):
            need(row['JointStatus'] == 5 and row['NumericStatus'] == 'DF2_SIGN_UNRESOLVED' and np.isnan(row['FValue']) and np.isnan(row['ProbF']), 'JOINT_UNSUPPORTED_DF_SIGN_REJECTED')
        elif df2 <= 0:
            need(cert['DF2Sign'] == -1 and row['JointStatus'] == 2 and (row['NumericStatus'] == 'INSUFFICIENT_EFFECTIVE_DF') and np.isnan(row['FValue']) and np.isnan(row['ProbF']), 'JOINT_UNSUPPORTED_DF_REJECTED')
        else:
            need(cert['DF2Sign'] == 1, 'JOINT_POSITIVE_DF_UNCERTIFIED')
            f = df2 * wald / (nu * q)
            pv = ibeta(df2 / 2, q / 2, df2 / (df2 + q * f))
            need(row['JointStatus'] == int(df2 < 4) and row['NumericStatus'] == ('LOW_EFFECTIVE_DF' if df2 < 4 else 'COMPUTED') and (0 <= row['ProbF'] <= 1), 'JOINT_STATUS_REJECTED')
            close(row['FValue'], f, rtol=2e-06, atol=1e-10)
            close(row['ProbF'], pv, rtol=2e-06, atol=1e-10)

def validate_archive(directory, prefix, expected_context, *, expected_files=None, export_started_ns=None, decimal_replay=None):
    """Return fixed validation status and private restart hashes; no model cells.

    expected_files is the exact ExpectedFiles mapping from an earlier successful
    validation. export_started_ns is a controller-held start timestamp, when used.
    Neither trusted binding may be populated from an untrusted archive manifest.
    decimal_replay: optional DecimalReplayRunner for fast-inconclusive scalar
    targets. Its operational failures (DecimalReplayUnavailable) propagate to the
    caller unchanged: the decimal stage is UNCERTIFIED, not scientifically rejected.
    """
    try:
        with np.errstate(over='raise', divide='raise', invalid='raise', under='ignore'):
            return _validate(directory, prefix, expected_context, expected_files, export_started_ns, decimal_replay)
    except DecimalReplayUnavailable:
        raise
    except Reject as error:
        return {'status': 'REJECTED', 'protocol': VALIDATION_PROTOCOL, 'reason_code': error.code, 'FullRunReady': False}
    except Exception:
        return {'status': 'REJECTED', 'protocol': VALIDATION_PROTOCOL, 'reason_code': 'CR2_ARCHIVE_VALIDATION_FAILED', 'FullRunReady': False}
