"""Validate the observed-data smooths and their supported time ranges."""
from __future__ import annotations
import csv, hashlib, json, math, re, stat
from pathlib import Path
from loess_report_contract import PROTOCOL, APPROVAL, METHOD, OUTCOMES, SPANS, CONTEXT, SCHEMAS, NUMERIC, ROWS, PUBLIC_ROLES, SUPPORT_STAGES, AVAILABLE, POINT_STATUSES, FIT_STATUSES, METHOD_CONSTANTS
from exact_numeric import parse_number, ExactNumericError

class Rejected(ValueError):

    def __init__(self, code):
        self.code = code
        super().__init__(code)

def need(ok, code):
    if not ok:
        raise Rejected(code)

def regular(p):
    st = p.stat(follow_symlinks=False)
    need(stat.S_ISREG(st.st_mode) and (not getattr(st, 'st_file_attributes', 0) & 1024), 'FILE_NOT_REGULAR')
    return st

def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def context_valid(c):
    need(isinstance(c, dict) and set(c) == set(CONTEXT), 'EXPECTED_CONTEXT_REQUIRED')
    need(all((isinstance(v, str) and 0 < len(v) <= 64 for v in c.values())), 'EXPECTED_CONTEXT_INVALID')
    for k in ('RunId', 'ReportRunId', 'ExportId'):
        need(bool(re.fullmatch('[0-9a-f]{32}', c[k])), 'EXPECTED_ID_INVALID')
    for k in ('CodeHash', 'ConfigHash', 'PreparationReceiptHash', 'ReportCodeHash', 'ReportConfigHash', 'ExportCodeHash'):
        need(bool(re.fullmatch('[0-9a-f]{64}', c[k])), 'EXPECTED_HASH_INVALID')
    need(c['CohortMode'] in ('development_sample', 'full_cohort') and c['PopulationId'] == 'PRIMARY' and (c['DisclosureStatus'] == 'PRIVATE_UNREVIEWED'), 'EXPECTED_SCOPE_INVALID')

def integer(v):
    return v is not None and 0 <= v <= 2 ** 53 and (v == int(v))

def parse(v):
    try:
        x = parse_number(v)
    except ExactNumericError:
        raise Rejected('NUMERIC_ENCODING_INVALID') from None
    need(math.isfinite(x) or math.isnan(x), 'NONFINITE_NUMERIC_REJECTED')
    return None if math.isnan(x) else x

def _validate_archive(directory, expected_context, *, export_started_ns=None, expected_files=None):
    context_valid(expected_context)
    need(export_started_ns is None or (type(export_started_ns) is int and export_started_ns > 0), 'FRESHNESS_TYPE_INVALID')
    need(type(export_started_ns) is int and export_started_ns > 0 or isinstance(expected_files, dict), 'TRUSTED_FRESHNESS_REQUIRED')
    root = Path(directory).absolute()
    need(root.is_dir() and (not root.is_symlink()), 'DIRECTORY_INVALID')
    for p in (root, *root.parents):
        need(not getattr(p.stat(follow_symlinks=False), 'st_file_attributes', 0) & 1024, 'REPARSE_PATH_REJECTED')
    required = set(PUBLIC_ROLES) | {'loess_manifest'}
    need({p.name for p in root.iterdir()} == {x + '.csv' for x in required}, 'EXCHANGE_MEMBER_SET_INVALID')
    bindings = {}
    total = 0

    def rows(role):
        nonlocal total
        p = root / (role + '.csv')
        before = regular(p)
        limit = (1024 if role == 'loess_predictions' else 16) * 2 ** 20
        need(0 < before.st_size <= limit, 'FILE_SIZE_INVALID')
        total += before.st_size
        need(total <= 1152 * 2 ** 20, 'BUNDLE_SIZE_INVALID')
        if export_started_ns is not None:
            need(before.st_mtime_ns >= export_started_ns, 'STALE_EXPORT')
        binding = {'sha256': digest(p), 'size': before.st_size}
        if expected_files is not None:
            need(expected_files.get(p.name) == binding, 'FILE_BINDING_MISMATCH')
        bindings[p.name] = binding
        count = 0
        with p.open('r', encoding='utf-8-sig', newline='') as f:
            reader = csv.DictReader(f)
            need(tuple(reader.fieldnames or ()) == SCHEMAS[role], 'CSV_SCHEMA_MISMATCH')
            for r in reader:
                count += 1
                need(count <= (4 if role == 'loess_manifest' else ROWS[role]), 'ROW_LIMIT_EXCEEDED')
                need(None not in r and all((isinstance(x, str) and len(x) <= 256 for x in r.values())), 'CSV_CELL_INVALID')
                for k in NUMERIC[role]:
                    r[k] = parse(r[k])
                yield r
        need(count == (4 if role == 'loess_manifest' else ROWS[role]), 'ROLE_CARDINALITY_INVALID')
        after = regular(p)
        need((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns), 'FILE_CHANGED_DURING_READ')
    manifest = {}
    for r in rows('loess_manifest'):
        role = r['Role']
        need(role in PUBLIC_ROLES and role not in manifest, 'MANIFEST_ROLE_INVALID')
        need(r['Protocol'] == PROTOCOL and r['LoessReportId'] == expected_context['ReportRunId'] and (r['ExportId'] == expected_context['ExportId']) and (r['ExportCodeHash'] == expected_context['ExportCodeHash']) and (r['FileName'] == role + '.csv') and (r['NumericFormat'] == 'HEX16_IEEE754') and (r['TextEncoding'] == 'UTF-8') and (r['ExportStatus'] == 'EXPORTED_LOCAL_ONLY') and (r['RowCount'] == ROWS[role]) and (r['ColumnCount'] == len(SCHEMAS[role])), 'MANIFEST_BINDING_INVALID')
        manifest[role] = r
    need(set(manifest) == set(PUBLIC_ROLES), 'MANIFEST_ROLE_SET_INVALID')
    metas = set()
    for r in rows('loess_metadata'):
        need(all((r[k] == v for k, v in expected_context.items())), 'CONTEXT_MISMATCH')
        need(r['VitalCode'] in OUTCOMES and r['VitalCode'] not in metas, 'METADATA_OUTCOME_INVALID')
        metas.add(r['VitalCode'])
        need(r['LoessReportId'] == expected_context['ReportRunId'] and all((r[k] == v for k, v in METHOD_CONSTANTS.items())), 'METHOD_CONTRACT_INVALID')
    statuses = {}
    for r in rows('loess_status'):
        key = (r['VitalCode'], r['SpanPercent'])
        need(r['LoessReportId'] == expected_context['ReportRunId'] and key[0] in OUTCOMES and (key[1] in SPANS) and (key not in statuses), 'STATUS_KEY_INVALID')
        need(r['FitStatus'] in FIT_STATUSES and r['PointStatusPolicy'] == 'EXPLICIT_GRID_STATUS_NO_EXTRAPOLATION', 'FIT_STATUS_INVALID')
        statuses[key] = r['FitStatus']
    support = {}
    for r in rows('loess_support'):
        key = (r['VitalCode'], r['SupportStage'])
        need(r['LoessReportId'] == expected_context['ReportRunId'] and key[0] in OUTCOMES and (key[1] in SUPPORT_STAGES) and (key not in support), 'SUPPORT_KEY_INVALID')
        need(r['DisclosureStatus'] == 'PRIVATE_UNREVIEWED' and r['OverlapSemantics'] == 'PERSON_EVENT_COUNTS_NONADDITIVE', 'SUPPORT_POLICY_INVALID')
        source = r['SupportStage'] in SUPPORT_STAGES[:2]
        need(r['CountUnit'] == ('SOURCE_ROWS' if source else 'EXACT_TIME_GROUPS'), 'COUNT_UNIT_INVALID')
        need(all((integer(r[k]) for k in ('NRows', 'NAvailableOutcome', 'NExactTimeGroups'))), 'SUPPORT_COUNTS_INVALID')
        need(r['NAvailableOutcome'] <= r['NRows'] and r['NExactTimeGroups'] <= r['NRows'], 'SUPPORT_COUNT_ORDER_INVALID')
        if source:
            need(integer(r['NKnownPersons']) and integer(r['NKnownEvents']) and (r['NKnownPersons'] <= r['NKnownEvents'] <= r['NRows']) and (r['NRetainedTimeGroups'] is None), 'SOURCE_SUPPORT_INVALID')
        else:
            need(r['NKnownPersons'] is None and r['NKnownEvents'] is None and (r['NRetainedTimeGroups'] == r['NRows'] == r['NExactTimeGroups']), 'TIME_GROUP_SUPPORT_INVALID')
        support[key] = r
    for v in OUTCOMES:
        stage = [support[v, s] for s in SUPPORT_STAGES]
        need(stage[1]['NRows'] <= stage[0]['NRows'] and stage[3]['NRows'] <= stage[2]['NRows'] and (stage[4]['NRows'] <= stage[3]['NRows']), 'SUPPORT_STAGE_ORDER_INVALID')
        for s in SPANS:
            need((statuses[v, s] == 'DIRECT_COMPLETED') == (stage[4]['NRows'] * s >= 300), 'FIT_SUPPORT_STATUS_MISMATCH')
            if stage[4]['NRows'] > 0 and stage[4]['NRows'] * s < 300:
                need(statuses[v, s] == 'INSUFFICIENT_SUPPORT', 'SPARSE_SPAN_STATUS_INVALID')
        need(stage[4]['NRows'] == (stage[3]['NAvailableOutcome'] if stage[3]['NAvailableOutcome'] * 90 >= 300 else 0), 'FIT_INPUT_COUNT_MISMATCH')
    seen = bytearray(ROWS['loess_predictions'])
    pair_state = {}
    support_state = {}
    for r in rows('loess_predictions'):
        v = r['VitalCode']
        s = r['SpanPercent']
        g = r['GridPointId']
        scale = r['ValueScale']
        ps = r['PointStatus']
        need(v in OUTCOMES and s in SPANS and integer(g) and (1 <= g <= 1441) and (scale in ('Z_SCORE', 'NATIVE')), 'PREDICTION_KEY_INVALID')
        ix = ((OUTCOMES.index(v) * 81 + int(s) - 10) * 1441 + int(g) - 1) * 2 + int(scale == 'NATIVE')
        need(not seen[ix], 'DUPLICATE_PREDICTION_KEY')
        seen[ix] = 1
        need(r['TimeFromTransfusion'] == g - 721 and r['LoessReportId'] == expected_context['ReportRunId'] and (r['MethodId'] == METHOD) and (r['GridId'] == 'MINUTE_-720_720_STEP_1') and (r['IntervalStatus'] == 'NOT_EXPORTED_DESCRIPTIVE') and (r['DisclosureStatus'] == 'PRIVATE_UNREVIEWED') and (r['MethodAdoptionStatus'] == APPROVAL), 'PREDICTION_POLICY_INVALID')
        need((r['Unit'], r['UnitStatus']) == (('SD', 'STANDARDIZED_GLOBAL_SD') if scale == 'Z_SCORE' else ('NATIVE', 'SOURCE_UNIT_UNCONFIRMED')), 'UNIT_STATUS_INVALID')
        need(ps in POINT_STATUSES, 'POINT_STATUS_INVALID')
        available = ps in AVAILABLE
        need(available == (r['Estimate'] is not None), 'ESTIMATE_MISSING_STATUS_MISMATCH')
        pairkey = (v, int(s), int(g))
        state = (ps, r['SupportStatus'], available)
        if pairkey in pair_state:
            other = pair_state.pop(pairkey)
            coherent = state == other or ((ps == 'NATIVE_TRANSFORM_UNAVAILABLE' or other[0] == 'NATIVE_TRANSFORM_UNAVAILABLE') and r['SupportStatus'] == other[1] == 'WITHIN_RETAINED_RANGE' and (available or other[2]))
            need(coherent, 'SCALE_PAIR_STATUS_MISMATCH')
        else:
            pair_state[pairkey] = state
        supportkey = (v, int(g))
        support = r['SupportStatus']
        if statuses[v, s] == 'DIRECT_COMPLETED':
            if supportkey in support_state:
                need(support_state[supportkey] == support, 'SPAN_SUPPORT_RANGE_MISMATCH')
            else:
                support_state[supportkey] = support
        if statuses[v, s] != 'DIRECT_COMPLETED':
            expected_support = 'INSUFFICIENT_FITTING_SUPPORT' if statuses[v, s] == 'INSUFFICIENT_SUPPORT' else 'NO_RETAINED_INPUT'
            need(ps == statuses[v, s] and r['SupportStatus'] == expected_support, 'UNAVAILABLE_FIT_STATUS_MISMATCH')
        elif ps in AVAILABLE or ps in ('FIT_UNAVAILABLE', 'NATIVE_TRANSFORM_UNAVAILABLE'):
            need(r['SupportStatus'] == 'WITHIN_RETAINED_RANGE', 'WITHIN_SUPPORT_STATUS_INVALID')
        elif ps == 'OUTSIDE_RETAINED_SUPPORT':
            need(r['SupportStatus'] == 'OUTSIDE_RETAINED_SUPPORT', 'OUTSIDE_SUPPORT_STATUS_INVALID')
        else:
            need(False, 'COMPLETED_FIT_STATUS_INVALID')
        if ps == 'NATIVE_TRANSFORM_UNAVAILABLE':
            need(scale == 'NATIVE', 'NATIVE_TRANSFORM_SCALE_INVALID')
    need(all(seen) and (not pair_state), 'PREDICTION_UNIVERSE_INCOMPLETE')
    for v in OUTCOMES:
        inside = [g for (outcome, g), state in support_state.items() if outcome == v and state == 'WITHIN_RETAINED_RANGE']
        if inside:
            need(len(inside) == max(inside) - min(inside) + 1, 'NONCONTIGUOUS_SUPPORT_RANGE')
    if expected_files is not None:
        need(set(expected_files) == set(bindings), 'FILE_BINDING_SET_MISMATCH')
    for name, b in bindings.items():
        p = root / name
        st = regular(p)
        need(st.st_size == b['size'] and digest(p) == b['sha256'], 'FILE_CHANGED_DURING_VALIDATION')
    archive_digest = hashlib.sha256(json.dumps(bindings, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'status': 'LOESS_ARCHIVE_VALIDATED', 'reason_code': 'PASS', 'Protocol': PROTOCOL, 'ArchiveContentDigest': archive_digest, 'ExpectedFiles': bindings, 'AllPlannedOutcomes': True, 'AllPlannedSpans': True, 'CompleteGridStatusUniverse': True, 'StrictFittedOnlyAllowlist': True, 'NoPublicIntervals': True, 'IndependentContextMatched': True, 'SourceDataReadByPython': False, 'NativeUnitSemanticsVerified': False}

def validate_archive(directory, expected_context, *, export_started_ns=None, expected_files=None):
    try:
        return _validate_archive(directory, expected_context, export_started_ns=export_started_ns, expected_files=expected_files)
    except Rejected:
        raise
    except (KeyError, TypeError, ValueError, IndexError, UnicodeError, csv.Error):
        raise Rejected('MALFORMED_LOESS_ARCHIVE') from None
    except OSError:
        raise Rejected('LOESS_EXCHANGE_IO_FAILED') from None
