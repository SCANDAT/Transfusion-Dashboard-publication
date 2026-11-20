"""Read and check the numerical tables exported by SAS."""
from pathlib import Path
import csv
import re
import numpy as np
from exact_numeric import decode_number, numeric_encoding
from recover_trajectory_covariance import reconstruct
from file_utils import regular_file
ANCHOR_TIMES = (-720, -660, -360, -60, 0, 60, 360, 660, 720)
_CONTEXT_CHARS = set('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId DFMethod JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind InferenceStatus'.split())
_ROLE_CHARS = {'identity': '', 'columns': 'ColumnName ParameterLabel', 'anchor_levels': '', 'anchor_diffs': '', 'anchor_design': '', 'score_design': '', 'column_scale': '', 'trajectory': 'VitalCode FactorName Model', 'within_changes': 'VitalCode FactorName Model Label RequestType', 'pairwise': 'VitalCode FactorName Model Label RequestType PAdjustment CIAdjustment', 'fitmetadata': 'VitalCode FactorName Model FitStatus ArchiveStatus DDFMethod CovarianceModel Optimizer ColumnScaleMethod KnotPolicy AdmissionCountStatus', 'knots': 'EffectName VariableName Basis KnotSource BoundaryRole', 'omnibus': 'VitalCode FactorName Model Estimand Label', 'interaction_test': 'VitalCode FactorName Model Estimand Label', 'categories': '', 'profile': 'PatientSex WardName', 'fitstats': 'Descr', 'covparms': 'CovParm', 'convergence': '', 'solution': 'Effect', 'cat_availability': 'AvailabilityReason', 'contrast_plan': 'ContrastID ContrastType ExclusionReason FamilyID', 'family_plan': 'FamilyID FamilyRole FactorName Model VitalCode PAdjustment CIAdjustment FreezeStage', 'job_status': 'JobStatus ReasonCode AdmissionCountStatus', 'inference_reference': 'CovarianceReference DFReference', 'archive_manifest': 'Role FileName SourceMember SourceKind NumericFormat TextEncoding ExportStatus ContentHashStatus'}

class CSVRow(dict):

    def __init__(self, row, encodings):
        super().__init__(row)
        self.numeric_encodings = frozenset(encodings)

def encoding_matches(rows, encoding):
    return encoding in {'HEX16_IEEE754', 'E32_STDIEEE'} and all((row.numeric_encodings <= {encoding} for row in rows))

class ExchangeError(ValueError):
    pass

def require(condition):
    if not condition:
        raise ExchangeError('EXCHANGE_CONTRACT_FAILED')

def table(folder, job, suffix, required):
    path = folder / (job + '_' + suffix + '.csv')
    require(regular_file(path, 64 * 1024 * 1024))
    with path.open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream)
        fields = reader.fieldnames or []
        require(len(fields) == len(set(fields)) and set(required) <= set(fields))
        rows = list(reader)
    require(all((None not in r and None not in r.values() for r in rows)))
    require(suffix in _ROLE_CHARS)
    chars = _CONTEXT_CHARS | set(_ROLE_CHARS[suffix].split())
    result = []
    for row in rows:
        encodings = set()
        for key in set(fields) - chars:
            raw = row[key]
            encoding = numeric_encoding(raw)
            if encoding is not None:
                encodings.add(encoding)
            if encoding == 'HEX16_IEEE754':
                row[key] = repr(decode_number(raw, allow_legacy=False, allow_missing=False))
        result.append(CSVRow(row, encodings))
    return (result, fields)

def number(row, key):
    value = row[key]
    try:
        x = decode_number(value, allow_legacy=True, allow_missing=False) if isinstance(value, str) else float(value)
    except (ValueError, TypeError, OverflowError):
        raise ExchangeError('EXCHANGE_CONTRACT_FAILED') from None
    require(np.isfinite(x))
    return x

def integer(row, key):
    x = number(row, key)
    require(x == int(x))
    return int(x)

def unique(rows, key):
    result = {integer(r, key): r for r in rows}
    require(len(result) == len(rows))
    return result

def validate_exchange(folder: Path, job: str, expected_categories: int):
    require(bool(re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,11}', job)))
    require(1 <= expected_categories <= 7)
    meta, _ = table(folder, job, 'fitmetadata', ('ResidualDF', 'DDFMethod', 'N_Categories', 'N_DesignColumns', 'N_Anchors'))
    require(len(meta) == 1)
    meta = meta[0]
    df = number(meta, 'ResidualDF')
    k = integer(meta, 'N_Categories')
    p = integer(meta, 'N_DesignColumns')
    require(df > 0 and meta['DDFMethod'] == 'RESIDUAL' and (k == expected_categories) and (p > 0))
    require(integer(meta, 'N_Anchors') == 9 * k)
    cols, _ = table(folder, job, 'columns', ('ColumnIndex', 'ColumnName'))
    colmap = unique(cols, 'ColumnIndex')
    require(set(colmap) == set(range(1, p + 1)))
    design_columns = ['RBCX' + str(i) for i in range(1, p + 1)]
    require([colmap[i]['ColumnName'].upper() for i in range(1, p + 1)] == design_columns)
    arows, afields = table(folder, job, 'anchor_design', ('AnchorID', 'GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', *design_columns))
    grows, gfields = table(folder, job, 'score_design', ('GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', *design_columns))
    require([c for c in afields if re.fullmatch('RBCX[0-9]+', c)] == design_columns)
    require([c for c in gfields if re.fullmatch('RBCX[0-9]+', c)] == design_columns)
    anchors = unique(arows, 'AnchorID')
    grid = unique(grows, 'GridID')
    require(set(anchors) == set(range(1, 9 * k + 1)) and len(grid) == 1441 * k)
    grid_ids = sorted(grid)
    grid_index = {gid: i for i, gid in enumerate(grid_ids)}
    coordinate = {}
    categories = {}
    for gid in grid_ids:
        row = grid[gid]
        c = integer(row, 'CategoryIndex')
        t = integer(row, 'TimeFromTransfusion')
        code = number(row, 'CategoryCode')
        require(1 <= c <= k and -720 <= t <= 720 and ((c, t) not in coordinate))
        require(c not in categories or categories[c] == code)
        categories[c] = code
        coordinate[c, t] = grid_index[gid]
    require(set(coordinate) == {(c, t) for c in range(1, k + 1) for t in range(-720, 721)})
    require(len(set(categories.values())) == k)
    observed_anchor_coordinates = set()
    for aid in sorted(anchors):
        row = anchors[aid]
        gid = integer(row, 'GridID')
        require(gid in grid)
        require(all((number(row, c) == number(grid[gid], c) for c in ['CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', *design_columns])))
        observed_anchor_coordinates.add((integer(row, 'CategoryIndex'), integer(row, 'TimeFromTransfusion')))
    require(observed_anchor_coordinates == {(c, t) for c in range(1, k + 1) for t in ANCHOR_TIMES})
    levels, _ = table(folder, job, 'anchor_levels', ('AnchorID', 'Estimate', 'StdErr', 'DF', 'Lower', 'Upper'))
    levels = unique(levels, 'AnchorID')
    require(set(levels) == set(anchors))
    diffs, _ = table(folder, job, 'anchor_diffs', ('LeftAnchor', 'RightAnchor', 'Estimate', 'StdErr', 'DF', 'Lower', 'Upper'))
    trajectory, _ = table(folder, job, 'trajectory', ('JobID', 'GridID', 'CategoryIndex', 'CategoryCode', 'TimeFromTransfusion', 'Predicted', 'StdErr', 'Delta', 'BaselineMinute'))
    trajectory = unique(trajectory, 'GridID')
    require(set(trajectory) == set(grid))
    for gid in grid_ids:
        row = trajectory[gid]
        require(row['JobID'] == job and integer(row, 'BaselineMinute') == -60)
        require(all((number(row, c) == number(grid[gid], c) for c in ('CategoryIndex', 'CategoryCode', 'TimeFromTransfusion'))))
        base_gid = grid_ids[coordinate[integer(row, 'CategoryIndex'), -60]]
        require(np.isclose(number(row, 'Delta'), number(row, 'Predicted') - number(trajectory[base_gid], 'Predicted'), rtol=1e-09, atol=1e-10))
    within, _ = table(folder, job, 'within_changes', ('JobID', 'RequestType', 'CategoryA', 'CategoryCodeA', 'Estimate', 'StdErr', 'DF', 'Lower', 'Upper', 'BeforeMinute', 'AfterMinute'))
    pairwise, _ = table(folder, job, 'pairwise', ('JobID', 'RequestType', 'CategoryA', 'CategoryB', 'CategoryCodeA', 'CategoryCodeB', 'Estimate', 'StdErr', 'DF', 'Lower', 'Upper', 'BeforeMinute', 'AfterMinute'))
    require(all((r['RequestType'] == 'WITHIN' for r in within)))
    require(all((r['RequestType'] == 'PAIRWISE' for r in pairwise)))
    for row in [*levels.values(), *diffs, *within, *pairwise]:
        estimate = number(row, 'Estimate')
        se = number(row, 'StdErr')
        require(se >= 0 and number(row, 'DF') == df and (number(row, 'Lower') <= estimate <= number(row, 'Upper')))
    direct = []
    seen_within = set()
    seen_pairs = set()
    for row in [*within, *pairwise]:
        require(row['JobID'] == job and integer(row, 'BeforeMinute') == -60 and (integer(row, 'AfterMinute') == 60))
        a = integer(row, 'CategoryA')
        require(a in categories and number(row, 'CategoryCodeA') == categories[a])
        weights = np.zeros(len(grid_ids))
        weights[coordinate[a, 60]] = 1
        weights[coordinate[a, -60]] = -1
        if row['RequestType'] == 'WITHIN':
            require(a not in seen_within)
            seen_within.add(a)
        else:
            require(row['RequestType'] == 'PAIRWISE')
            b = integer(row, 'CategoryB')
            require(1 <= a < b <= k and (a, b) not in seen_pairs and (number(row, 'CategoryCodeB') == categories[b]))
            seen_pairs.add((a, b))
            weights[coordinate[b, 60]] = -1
            weights[coordinate[b, -60]] = 1
        direct.append((weights, number(row, 'Estimate'), number(row, 'StdErr')))
    require(seen_within == set(range(1, k + 1)))
    require(seen_pairs == {(a, b) for a in range(1, k + 1) for b in range(a + 1, k + 1)})
    anchor_coords = {(integer(r, 'CategoryIndex'), integer(r, 'TimeFromTransfusion')): aid for aid, r in anchors.items()}
    pair_lookup = {(integer(r, 'LeftAnchor'), integer(r, 'RightAnchor')): r for r in diffs}
    require(len(pair_lookup) == len(diffs))
    for category in range(1, k + 1):
        early = anchor_coords[category, -360]
        late = anchor_coords[category, 360]
        require(early < late and (early, late) in pair_lookup)
        pair = pair_lookup[early, late]
        later = np.zeros(len(grid_ids))
        later[coordinate[category, 360]] = 1
        later[coordinate[category, -360]] = -1
        direct.append((later, -number(pair, 'Estimate'), number(pair, 'StdErr')))
    archive = reconstruct([number(levels[i], 'Estimate') for i in sorted(levels)], [number(levels[i], 'StdErr') for i in sorted(levels)], [(integer(r, 'LeftAnchor') - 1, integer(r, 'RightAnchor') - 1, number(r, 'Estimate'), number(r, 'StdErr')) for r in diffs], [[number(anchors[i], c) for c in design_columns] for i in sorted(anchors)], [[number(grid[i], c) for c in design_columns] for i in grid_ids], [number(trajectory[i], 'Predicted') for i in grid_ids], [number(trajectory[i], 'StdErr') for i in grid_ids], direct_contrasts=direct)
    return archive
