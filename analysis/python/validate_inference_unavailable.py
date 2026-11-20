"""Verify the evidence for a fit with unavailable inference."""
from __future__ import annotations
import csv, hashlib, io, json, math, re, stat
from pathlib import Path
from file_utils import ValidationRejected
from exact_numeric import parse_number
from validate_model_exchange import table, number, integer, ExchangeError
from validate_model_archive import CONTEXT as WORKING_CONTEXT, REQUIRED_EXPECTED, FACTOR_LEVELS
from derive_model_trajectory import _input_digest
import inference_availability as policy
MAX_FILE_BYTES = 16 * 2 ** 20
TOKEN = re.compile('[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}')
WORKING_PROTOCOL = 'RBC_MODEL_ARCHIVE_VALIDATION_V1'
VALIDATED = 'INFERENCE_UNAVAILABLE_VALIDATED'

def reject(code):
    raise ValidationRejected(code)

def need(value, code):
    if not value:
        reject(code)

def _ancestors(path):
    for item in (path, *path.parents):
        x = item.lstat()
        need(not stat.S_ISLNK(x.st_mode) and (not getattr(x, 'st_file_attributes', 0) & 1024), 'REPARSE_PATH_REJECTED')

def _state(path):
    path = Path(path).absolute()
    _ancestors(path)
    x = path.lstat()
    need(stat.S_ISREG(x.st_mode) and 0 < x.st_size <= MAX_FILE_BYTES, 'FILE_TYPE_REJECTED')
    return (x.st_size, x.st_mtime_ns, x.st_dev, x.st_ino)

def _directory(path):
    path = Path(path).absolute()
    _ancestors(path)
    need(stat.S_ISDIR(path.lstat().st_mode), 'DIRECTORY_REJECTED')

class _Intake:
    """Exact-schema, identity-bound, freshness-bound reading of the archive CSVs."""

    def __init__(self, folder, prefix, started):
        self.folder = Path(folder).absolute()
        _directory(self.folder)
        self.prefix = prefix
        self.started = started
        self.before = {}
        self.hashes = {}

    def load(self, role, chars, nums, *, count=None, limit=10000, identity=None):
        fields = policy.CONTEXT + tuple(chars) + tuple(nums)
        name = policy.file_name(self.prefix, role)
        path = self.folder / name
        before = _state(path)
        need(before[1] >= self.started, 'STALE_EXPORT_REJECTED')
        raw = path.read_bytes()
        need(_state(path) == before and len(raw) == before[0], 'FILE_CHANGED_REJECTED')
        need(role not in self.before, 'DUPLICATE_ROLE_REJECTED')
        self.before[role] = before
        self.hashes[name] = {'sha256': hashlib.sha256(raw).hexdigest(), 'size_bytes': len(raw)}
        need(b'\x00' not in raw, 'CSV_TEXT_REJECTED')
        try:
            text = raw.decode('utf-8-sig')
        except UnicodeError:
            reject('CSV_TEXT_REJECTED')
        reader = csv.reader(io.StringIO(text, newline=''), strict=True)
        header = next(reader, None)
        need(header is not None, 'SCHEMA_REJECTED')
        mapping = {f.casefold(): f for f in fields}
        folded = [h.casefold() for h in header]
        need(len(folded) == len(fields) and len(set(folded)) == len(fields) and (set(folded) == set(mapping)), 'SCHEMA_REJECTED')
        names = [mapping[h] for h in folded]
        numeric = set(policy.CONTEXT_NUMS) | set(nums)
        rows = []
        for cells in reader:
            need(len(cells) == len(names) and all((len(c) <= 256 for c in cells)), 'CSV_ROW_REJECTED')
            row = {}
            for key, cell in zip(names, cells):
                if key in numeric:
                    try:
                        value = parse_number(cell)
                    except ValueError:
                        reject('CSV_NUMERIC_REJECTED')
                    row[key] = None if math.isnan(value) else value
                else:
                    row[key] = cell
            if identity is not None:
                need(all((row[k] == identity[k] for k in policy.CONTEXT)), 'CONTEXT_REJECTED')
            rows.append(row)
            need(len(rows) <= (count if count is not None else limit), 'ROW_COUNT_REJECTED')
        if count is not None:
            need(len(rows) == count, 'ROW_COUNT_REJECTED')
        return rows

    def finish(self):
        expected = policy.file_names(self.prefix)
        need({p.name for p in self.folder.iterdir()} == expected, 'UNEXPECTED_FILE_REJECTED')
        need({policy.file_name(self.prefix, r) for r in self.before} == expected, 'ROLE_INVENTORY_REJECTED')
        manifest_time = self.before['archive_manifest'][1]
        for role, before in self.before.items():
            path = self.folder / policy.file_name(self.prefix, role)
            need(before[1] <= manifest_time, 'MANIFEST_FRESHNESS_REJECTED')
            need(_state(path) == before, 'FILE_CHANGED_REJECTED')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            need(_state(path) == before and digest == self.hashes[path.name]['sha256'], 'FILE_CHANGED_REJECTED')
        return hashlib.sha256(json.dumps(self.hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def _optional(row, key):
    value = row[key]
    return None if value in ('', '.') else number(row, key)

def _canonical_working(rows, chars, nums):
    """Typed multiset of validated working rows (table() decodes HEX16 to exact repr)."""
    out = []
    for row in rows:
        values = [('C', row[k]) for k in chars]
        for k in nums:
            v = _optional(row, k)
            values.append(('N', 'MISSING' if v is None else float(v).hex()))
        out.append(tuple(values))
    return sorted(out)

def _canonical_archive(rows, chars, nums):
    out = []
    for row in rows:
        values = [('C', row[k]) for k in chars]
        for k in nums:
            v = row[k]
            values.append(('N', 'MISSING' if v is None else float(v).hex()))
        out.append(tuple(values))
    return sorted(out)

def _working(folder, job, expected, report):
    """Pre-fit counts, plan and scoring design of the ALREADY validated working archive."""
    need(isinstance(report, dict) and report.get('status') == 'VALIDATED' and (report.get('protocol') == WORKING_PROTOCOL), 'WORKING_VALIDATION_REQUIRED')
    try:
        current = _input_digest(Path(folder), job)
    except ExchangeError:
        reject('WORKING_ARCHIVE_BINDING_CHANGED')
    need(current == report.get('ArchiveContentDigest'), 'WORKING_ARCHIVE_BINDING_CHANGED')
    identity, _ = table(folder, job, 'identity', WORKING_CONTEXT)
    need(len(identity) == 1, 'WORKING_IDENTITY_REJECTED')
    identity = identity[0]
    need(all((identity[k] == expected[k] for k in REQUIRED_EXPECTED if k in WORKING_CONTEXT)), 'WORKING_IDENTITY_REJECTED')
    need(identity['DFMethod'] == 'RESIDUAL' and identity['InferenceStatus'] == 'MODEL_BASED_CANDIDATE' and (integer(identity, 'BindingVersion') == 1), 'WORKING_IDENTITY_REJECTED')
    meta, _ = table(folder, job, 'fitmetadata', ('FitStatus', 'EngineRunChecksPassed', 'N_DesignColumns', 'N_Categories', 'N_Patients'))
    need(len(meta) == 1, 'WORKING_FIT_REJECTED')
    meta = meta[0]
    p = integer(meta, 'N_DesignColumns')
    k = integer(meta, 'N_Categories')
    persons = integer(meta, 'N_Patients')
    need(meta['FitStatus'] == 'FIT_CHECKS_PASSED' and integer(meta, 'EngineRunChecksPassed') == 1 and (1 <= p <= 200) and (2 <= k <= 7) and (persons >= 2), 'WORKING_FIT_REJECTED')
    levels = FACTOR_LEVELS[expected['FactorName']]
    planned = len(levels)
    plan_fields = ('CategoryCode', 'CategoryIndex', 'N_Observations', 'N_Patients', 'Available', 'AvailabilityReason')
    cats, _ = table(folder, job, 'cat_availability', plan_fields)
    need(len(cats) == planned, 'WORKING_PLAN_REJECTED')
    available = {}
    single = []
    seen = set()
    for row in cats:
        code = integer(row, 'CategoryCode')
        flag = integer(row, 'Available')
        need(code in levels and code not in seen and (flag in (0, 1)), 'WORKING_PLAN_REJECTED')
        seen.add(code)
        if flag:
            index = integer(row, 'CategoryIndex')
            persons_c = integer(row, 'N_Patients')
            need(1 <= index <= k and persons_c >= 1 and (integer(row, 'N_Observations') >= persons_c), 'WORKING_PLAN_REJECTED')
            available[code] = index
            if persons_c == 1:
                single.append(code)
        else:
            need(_optional(row, 'CategoryIndex') is None and integer(row, 'N_Patients') == 0, 'WORKING_PLAN_REJECTED')
    need(sorted(available.values()) == list(range(1, k + 1)), 'WORKING_PLAN_REJECTED')
    need(single, 'NO_SINGLE_PERSON_ACTIVE_CATEGORY')
    columns = ['RBCX' + str(i) for i in range(1, p + 1)]
    score, _ = table(folder, job, 'score_design', ('GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', *columns))
    need(len(score) == 1441 * k, 'WORKING_SCORING_REJECTED')
    code_of = {index: code for code, index in available.items()}
    design = {}
    for row in score:
        c = integer(row, 'CategoryIndex')
        t = integer(row, 'TimeFromTransfusion')
        need(c in code_of and -720 <= t <= 720 and ((c, t) not in design) and (integer(row, 'CategoryCode') == code_of[c]), 'WORKING_SCORING_REJECTED')
        design[c, t] = [number(row, x) for x in columns]
    need(len(design) == 1441 * k, 'WORKING_SCORING_REJECTED')
    nonzero = {c: [any((design[c, t][j] != 0 for t in range(-720, 721))) for j in range(p)] for c in range(1, k + 1)}
    certificate = []
    for code in sorted(single):
        c = available[code]
        within = [design[c, 60][j] - design[c, -60][j] for j in range(p)]
        specific = [nonzero[c][j] and (not any((nonzero[d][j] for d in range(1, k + 1) if d != c))) for j in range(p)]
        derived = [(code, c, j + 1) for j in range(p) if specific[j] and within[j] != 0]
        need(derived, 'CERTIFICATE_DERIVATION_EMPTY')
        certificate.extend(derived)
    contrast, _ = table(folder, job, 'contrast_plan', policy.ROLE_SCHEMAS['contrast_plan'][0] + policy.ROLE_SCHEMAS['contrast_plan'][1])
    family, _ = table(folder, job, 'family_plan', policy.ROLE_SCHEMAS['family_plan'][0] + policy.ROLE_SCHEMAS['family_plan'][1])
    need(len(contrast) == planned + planned * (planned - 1) // 2 and len(family) == 1, 'WORKING_PLAN_REJECTED')
    plans = {role: _canonical_working(rows, *policy.ROLE_SCHEMAS[role]) for role, rows in (('cat_availability', cats), ('contrast_plan', contrast), ('family_plan', family))}
    return dict(identity=identity, p=p, k=k, persons=persons, planned=planned, available=available, single=sorted(single), certificate=sorted(certificate), plans=plans)

def _validate(directory, prefix, expected, *, working_folder, job, working_report, export_started_ns):
    need(isinstance(job, str) and re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,11}', job) is not None, 'JOB_REJECTED')
    need(isinstance(prefix, str) and re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,8}', prefix) is not None and (prefix == 'C' + job[1:]), 'PREFIX_REJECTED')
    need(isinstance(expected, dict) and set(REQUIRED_EXPECTED) <= set(expected) and (expected['JobID'] == job), 'EXPECTED_CONTEXT_REQUIRED')
    need(all((isinstance(expected[k], str) and TOKEN.fullmatch(expected[k]) for k in REQUIRED_EXPECTED)), 'EXPECTED_CONTEXT_REJECTED')
    need(expected['CohortMode'] in policy.SCOPE_PAIRS and expected['FactorName'] in FACTOR_LEVELS and (expected['FactorName'] != 'NONE'), 'EXPECTED_CONTEXT_REJECTED')
    try:
        bound = policy.policy(expected.get(policy.CONFIG_KEY))
    except policy.AvailabilityRejected:
        reject('EXPECTED_CONTEXT_REJECTED')
    need(bound == policy.SPCU_V1, 'INFERENCE_UNAVAILABLE_POLICY_NOT_BOUND')
    need(type(export_started_ns) is int and export_started_ns > 0, 'TRUSTED_FRESHNESS_REQUIRED')
    w = _working(working_folder, job, expected, working_report)
    intake = _Intake(directory, prefix, export_started_ns)
    need({p.name for p in intake.folder.iterdir()} == policy.file_names(prefix), 'UNEXPECTED_FILE_REJECTED')
    identity = intake.load('identity', (), (), count=1)[0]
    wid = w['identity']
    required = {k: wid[k] for k in policy.COPIED_WORKING}
    required.update(WorkingDFMethod=wid['DFMethod'], WorkingInferenceStatus=wid['InferenceStatus'], Scope=policy.SCOPE_PAIRS[expected['CohortMode']], PlannedCovarianceMethod=policy.PLANNED_COVARIANCE, InferenceStatus=policy.INFERENCE_STATUS, InferencePolicy=policy.SPCU_V1, InferenceArchiveID=prefix, SupportCertificate=policy.SUPPORT_CERTIFICATE, BindingVersion=1.0, WorkingBindingVersion=float(integer(wid, 'BindingVersion')))
    need(all((identity[k] == v for k, v in required.items())), 'IDENTITY_REJECTED')
    need(all((identity[k] == expected[k] for k in REQUIRED_EXPECTED if k in policy.CONTEXT)), 'IDENTITY_REJECTED')
    need(all((isinstance(identity[k], str) and TOKEN.fullmatch(identity[k]) for k in policy.CONTEXT_CHARS)), 'IDENTITY_REJECTED')
    chars, nums = policy.ROLE_SCHEMAS['status']
    status = intake.load('status', chars, nums, count=1, identity=identity)[0]
    expected_status = dict(IntegrationStatus=policy.INTEGRATION_STATUS, ReasonCode=policy.KERNEL_REASON, SupportReason=policy.SUPPORT_REASON, UnavailableScope=policy.UNAVAILABLE_SCOPE, TargetClaim=policy.TARGET_CLAIM, StatisticsPolicy=policy.STATISTICS_POLICY, PlannedCategories=float(w['planned']), ActiveCategories=float(w['k']), PlannedScalarTargets=float(policy.planned_scalar_targets(w['k'])), PlannedJointTests=float(policy.planned_joint_tests(w['k'])), SinglePersonCategories=float(len(w['single'])), CertificateColumns=float(len(w['certificate'])), ParameterCount=float(w['p']), ClusterCount=float(w['persons']))
    need(all((status[k] == v for k, v in expected_status.items())), 'STATUS_REJECTED')
    manifest = intake.load('archive_manifest', policy.MANIFEST_CHARS, policy.MANIFEST_NUMS, count=len(policy.ROLES), identity=identity)
    by_role = {}
    for row in manifest:
        role = row['Role']
        need(role in policy.ROLE_SCHEMAS and role not in by_role, 'MANIFEST_REJECTED')
        by_role[role] = row
        need(row['Protocol'] == policy.ARCHIVE_PROTOCOL and row['FileName'] == policy.file_name(prefix, role) and (row['NumericFormat'] == policy.NUMERIC_FORMAT) and (row['TextEncoding'] == 'UTF-8') and (row['ExportStatus'] == 'EXPORTED_LOCAL_ONLY'), 'MANIFEST_REJECTED')
        c, n = policy.ROLE_SCHEMAS[role]
        need(row['ColumnCount'] == float(len(policy.CONTEXT) + len(c) + len(n)), 'MANIFEST_REJECTED')
    need(set(by_role) == set(policy.ROLES), 'MANIFEST_REJECTED')
    need(by_role['identity']['RowCount'] == 1.0 and by_role['status']['RowCount'] == 1.0, 'MANIFEST_REJECTED')
    tables = {}
    for role, count in (('cat_availability', w['planned']), ('contrast_plan', w['planned'] + w['planned'] * (w['planned'] - 1) // 2), ('family_plan', 1), ('support_certificate', len(w['certificate']))):
        need(by_role[role]['RowCount'] == float(count), 'MANIFEST_REJECTED')
        tables[role] = intake.load(role, *policy.ROLE_SCHEMAS[role], count=count, identity=identity)
    for role in ('cat_availability', 'contrast_plan', 'family_plan'):
        need(_canonical_archive(tables[role], *policy.ROLE_SCHEMAS[role]) == w['plans'][role], 'FROZEN_PLAN_CHANGED')
    observed = []
    for row in tables['support_certificate']:
        need(row['CertificateKind'] == policy.CERTIFICATE_KIND and row['WithinCoefficientNonzero'] == 1.0 and (row['CategorySpecificInScoring'] == 1.0) and (row['SupportPersonsCappedAt2'] == 1.0), 'SUPPORT_CERTIFICATE_REJECTED')
        values = [row[x] for x in ('CategoryCode', 'CategoryIndex', 'ColumnIndex')]
        need(all((v is not None and v == int(v) for v in values)), 'SUPPORT_CERTIFICATE_REJECTED')
        observed.append(tuple((int(v) for v in values)))
    need(len(set(observed)) == len(observed) and sorted(observed) == w['certificate'], 'SUPPORT_CERTIFICATE_NOT_SUBSTANTIATED')
    digest = intake.finish()
    record = policy.build_record(planned=w['planned'], active=w['k'], single_codes=w['single'], certificate_rows=w['certificate'])
    return {'status': VALIDATED, 'protocol': policy.VALIDATION_PROTOCOL, 'reason_code': policy.KERNEL_REASON, 'ArchiveContentDigest': digest, 'ExpectedFiles': intake.hashes, policy.RECORD_KEY: record, 'WorkingArchiveContentDigest': working_report['ArchiveContentDigest'], 'ValidationScope': 'EXACT_SCHEMA_IDENTITY_FROZEN_PLAN_NO_STATISTICS_EXCLUSIVE_SUPPORT_REDERIVED', 'ScientificApproval': 'NOT_GRANTED', 'FullRunReady': False}

def validate_archive(directory, prefix, expected_context, *, working_folder, job, working_report, export_started_ns):
    """Fixed feedback boundary. Raises ValidationRejected(code) on any contract failure."""
    try:
        return _validate(Path(directory), prefix, expected_context, working_folder=Path(working_folder), job=job, working_report=working_report, export_started_ns=export_started_ns)
    except ValidationRejected:
        raise
    except (OSError, MemoryError):
        raise
    except ExchangeError:
        raise ValidationRejected('WORKING_ARCHIVE_REJECTED') from None
    except policy.AvailabilityRejected as error:
        raise ValidationRejected(error.code) from None
    except Exception:
        raise ValidationRejected('INFERENCE_UNAVAILABLE_ARCHIVE_MALFORMED') from None

def _single_person_evidence(folder, job, expected, report):
    need(isinstance(job, str) and re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,11}', job) is not None, 'JOB_REJECTED')
    need(isinstance(expected, dict) and set(REQUIRED_EXPECTED) <= set(expected) and (expected['JobID'] == job) and (expected['FactorName'] in FACTOR_LEVELS), 'EXPECTED_CONTEXT_REQUIRED')
    need(isinstance(report, dict) and report.get('status') == 'VALIDATED' and (report.get('protocol') == WORKING_PROTOCOL) and isinstance(report.get('ArchiveContentDigest'), str) and (re.fullmatch('[0-9a-f]{64}', report['ArchiveContentDigest']) is not None), 'WORKING_VALIDATION_REQUIRED')
    bound = report['ArchiveContentDigest']
    try:
        before = _input_digest(folder, job)
    except ExchangeError:
        reject('WORKING_ARCHIVE_BINDING_CHANGED')
    need(before == bound, 'WORKING_ARCHIVE_BINDING_CHANGED')
    identity, _ = table(folder, job, 'identity', ('JobID', 'FitId'))
    need(len(identity) == 1 and identity[0]['JobID'] == job and (identity[0]['FitId'] == expected['FitId']), 'WORKING_IDENTITY_REJECTED')
    meta, _ = table(folder, job, 'fitmetadata', ('FitStatus', 'EngineRunChecksPassed', 'N_Categories', 'N_Patients'))
    need(len(meta) == 1, 'WORKING_FIT_REJECTED')
    meta = meta[0]
    k = integer(meta, 'N_Categories')
    persons = integer(meta, 'N_Patients')
    need(meta['FitStatus'] == 'FIT_CHECKS_PASSED' and integer(meta, 'EngineRunChecksPassed') == 1 and (1 <= k <= 7) and (persons >= 2), 'WORKING_FIT_REJECTED')
    levels = FACTOR_LEVELS[expected['FactorName']]
    cats, _ = table(folder, job, 'cat_availability', ('CategoryCode', 'CategoryIndex', 'N_Observations', 'N_Patients', 'Available'))
    need(len(cats) == len(levels), 'WORKING_PLAN_REJECTED')
    seen = set()
    indices = []
    single = []
    for row in cats:
        code = integer(row, 'CategoryCode')
        flag = integer(row, 'Available')
        count = integer(row, 'N_Patients')
        need(code in levels and code not in seen and (flag in (0, 1)), 'WORKING_PLAN_REJECTED')
        seen.add(code)
        if flag:
            indices.append(integer(row, 'CategoryIndex'))
            need(1 <= count <= persons and integer(row, 'N_Observations') >= count, 'WORKING_PLAN_REJECTED')
            if count == 1:
                single.append(code)
        else:
            need(_optional(row, 'CategoryIndex') is None and count == 0, 'WORKING_PLAN_REJECTED')
    need(sorted(indices) == list(range(1, k + 1)), 'WORKING_PLAN_REJECTED')
    try:
        after = _input_digest(folder, job)
    except ExchangeError:
        reject('WORKING_ARCHIVE_BINDING_CHANGED')
    need(after == bound, 'WORKING_ARCHIVE_BINDING_CHANGED')
    return dict(SinglePersonCategoryCodes=sorted(single), ActiveCategories=k, PlannedCategories=len(levels), WorkingArchiveContentDigest=bound)

def working_single_person_codes(working_folder, job, expected_context, *, working_report):
    """Fixed feedback boundary. Raises ValidationRejected(code) on any contract failure."""
    try:
        return _single_person_evidence(Path(working_folder), job, expected_context, working_report)
    except ValidationRejected:
        raise
    except (OSError, MemoryError):
        raise
    except ExchangeError:
        raise ValidationRejected('WORKING_ARCHIVE_REJECTED') from None
    except Exception:
        raise ValidationRejected('WORKING_ARCHIVE_REJECTED') from None
