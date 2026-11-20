"""Verify the retained model estimates, contrasts and uncertainty calculations."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import numpy as np
from validate_model_exchange import validate_exchange, table, require, number, integer, unique, ExchangeError, encoding_matches
from file_utils import regular_file, private_directory
from fit_status_contract import validate_plan, validate_admission_count, PLAN_FIELDS, PLAN_ROLES
CONTEXT = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId DFMethod JobID SubjectKeySource SubjectAlias DesignIdentityKind ProfileIdentityKind InferenceStatus BindingVersion'.split())
ROLES = tuple('identity columns anchor_levels anchor_diffs anchor_design score_design trajectory within_changes pairwise fitmetadata knots column_scale omnibus interaction_test categories profile fitstats covparms convergence solution inference_reference'.split()) + PLAN_ROLES
FIXED_FIELDS = {'identity': '', 'columns': 'ColumnName ParameterLabel InputPosition VariableType ColumnIndex', 'anchor_levels': 'AnchorID Estimate StdErr DF Lower Upper', 'anchor_diffs': 'LeftAnchor RightAnchor Estimate StdErr DF Lower Upper', 'anchor_design': 'AnchorID GridID CategoryIndex CategoryCode TimeFromTransfusion', 'score_design': 'GridID CategoryIndex CategoryCode TimeFromTransfusion', 'trajectory': 'VitalCode FactorName Model GridID CategoryIndex CategoryCode TimeFromTransfusion Predicted StdErr Lower Upper Delta BaselineMinute', 'within_changes': 'VitalCode FactorName Model Label RequestType AnchorA AnchorB CategoryA CategoryB CategoryCodeA CategoryCodeB Estimate StdErr DF PValue Lower Upper BeforeMinute AfterMinute', 'pairwise': 'VitalCode FactorName Model Label RequestType PAdjustment CIAdjustment AnchorA AnchorB CategoryA CategoryB CategoryCodeA CategoryCodeB Estimate StdErr DF PValue Lower Upper BeforeMinute AfterMinute FamilySize Rank PValue_Holm', 'fitmetadata': 'VitalCode FactorName Model FitStatus ArchiveStatus DDFMethod CovarianceModel Optimizer ColumnScaleMethod KnotPolicy N_Scope N_Used N_Excluded_Missing N_Patients N_Events N_Admissions AdmissionCountStatus N_Categories N_DesignColumns N_Anchors N_RequestedEstimates BeforeMinute AfterMinute ResidualDF GConv AbsGConv MaxIter EngineRunChecksPassed', 'knots': 'EffectName VariableName Basis KnotSource BoundaryRole KnotNumber KnotValue ExpectedKnots', 'column_scale': '', 'omnibus': 'VitalCode FactorName Model Estimand Label NumDF DenDF FValue ProbF', 'interaction_test': 'VitalCode FactorName Model Estimand Label NumDF DenDF FValue ProbF', 'categories': 'CategoryIndex CategoryCode N_Observations N_Patients N_Events', 'profile': 'PatientSex WardName PatientAge ICU_time RBC_Count', 'fitstats': 'Descr Value', 'covparms': 'CovParm Estimate', 'convergence': 'Status', 'solution': 'Effect Estimate StdErr DF tValue Probt', 'inference_reference': 'CovarianceReference DFReference Alpha DF CriticalValue'}
FIXED_FIELDS.update(PLAN_FIELDS)
MANIFEST_FIELDS = tuple('Role FileName SourceMember SourceKind NumericFormat TextEncoding ExportStatus ContentHashStatus ArchiveVersion RowCount ColumnCount'.split())
FACTOR_LEVELS = {'NONE': {1}, 'DonorHb_Cat': {1, 2, 3, 4, 5}, 'Storage_Cat': {1, 2, 3, 4, 5}, 'DonorSex': {1, 2}, 'DonorParity_Female': {0, 1}, 'wdy_donation': {1, 2, 3, 4, 5, 6, 7}}
REQUIRED_EXPECTED = tuple('RunId AnalysisSpecId CohortMode PopulationId FitId InputSnapshotId CodeHash ConfigHash DesignId ProfileId JobID Model FactorName VitalCode'.split())

def _close(a, b, rtol=1e-07, atol=1e-12):
    require(bool(np.isclose(a, b, rtol=rtol, atol=atol)))

def _file_state(path):
    require(regular_file(path, 64 * 1024 * 1024))
    info = path.stat()
    return (info.st_size, info.st_mtime_ns, info.st_dev, info.st_ino)

def _ci(row, critical, estimate='Estimate'):
    center = number(row, estimate)
    se = number(row, 'StdErr')
    require(se >= 0)
    tolerance = 1e-10 * max(abs(center), abs(critical * se), 1e-100)
    _close(number(row, 'Lower'), center - critical * se, atol=tolerance)
    _close(number(row, 'Upper'), center + critical * se, atol=tolerance)

def _wald(weights, archive, row, df):
    weights = np.asarray(weights, float)
    mu = weights @ archive.anchor_mean
    covariance = weights @ archive.anchor_covariance @ weights.T
    scales = np.sqrt(np.maximum(0, np.diag(covariance)))
    require((scales > 0).all())
    correlation = covariance / scales[:, None] / scales[None, :]
    require(np.linalg.matrix_rank(correlation, tol=1e-10) == len(weights))
    statistic = float(mu / scales @ np.linalg.solve(correlation, mu / scales) / len(weights))
    require(integer(row, 'NumDF') == len(weights) and number(row, 'DenDF') == df)
    require(0 <= number(row, 'ProbF') <= 1)
    _close(number(row, 'FValue'), statistic, rtol=2e-06, atol=1e-10)

def _validate(folder: Path, job: str, expected: dict) -> dict:
    """Return fixed validation status + model-content digest, never model values."""
    folder = Path(folder)
    require(private_directory(folder))
    require(bool(re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,11}', job)))
    require(isinstance(expected, dict) and set(REQUIRED_EXPECTED) <= set(expected))
    require(all((isinstance(expected[key], str) and expected[key] for key in REQUIRED_EXPECTED)))
    require(expected['JobID'] == job)
    require(expected['CohortMode'] in {'synthetic', 'development_sample', 'full_cohort'})
    require(bool(re.fullmatch('[0-9a-f]{32}', expected['RunId'])))
    require(all((re.fullmatch('[0-9a-f]{64}', expected[k]) for k in ('CodeHash', 'ConfigHash'))))
    require(expected['Model'] in {'BASE', 'FULL'} and expected['FactorName'] in FACTOR_LEVELS)
    require(expected['VitalCode'] in {'ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE'})
    paths = {role: folder / (job + '_' + role + '.csv') for role in (*ROLES, 'archive_manifest')}
    before = {role: _file_state(path) for role, path in paths.items()}
    manifest, mfields = table(folder, job, 'archive_manifest', (*CONTEXT, *MANIFEST_FIELDS))
    require(set(mfields) == set(CONTEXT) | set(MANIFEST_FIELDS))
    require(len(manifest) == len(ROLES) and {r['Role'] for r in manifest} == set(ROLES))
    manifest_map = {r['Role']: r for r in manifest}
    formats = {r['NumericFormat'] for r in manifest}
    require(len(formats) == 1)
    numeric_format = next(iter(formats))
    require(encoding_matches(manifest, numeric_format))
    identity, ifields = table(folder, job, 'identity', CONTEXT)
    require(len(identity) == 1 and set(ifields) == set(CONTEXT))
    require(encoding_matches(identity, numeric_format))
    identity = identity[0]
    require(all((identity[key] == expected[key] for key in REQUIRED_EXPECTED if key in CONTEXT)))
    require(identity['DFMethod'] == 'RESIDUAL' and integer(identity, 'BindingVersion') == 1)
    require(identity['SubjectAlias'] == 'PatientID')
    require(identity['InferenceStatus'] == 'MODEL_BASED_CANDIDATE')
    require(identity['DesignIdentityKind'] == 'ASSIGNED_ID_NOT_CONTENT_HASH' and identity['ProfileIdentityKind'] == 'ASSIGNED_ID_NOT_CONTENT_HASH')
    require(identity['SubjectKeySource'] == ('SYNTHETIC_PERSON' if expected['CohortMode'] == 'synthetic' else 'PersonKey'))
    for row in manifest:
        require(all((row[key] == identity[key] for key in CONTEXT)))
        role = row['Role']
        require(row['FileName'] == paths[role].name)
        require(row['SourceMember'].upper() == (job + '_' + role).upper())
        require(row['SourceKind'] == ('DERIVED_MODEL_REFERENCE' if role == 'inference_reference' else 'SOURCE_MODEL_TABLE'))
        require(row['NumericFormat'] == numeric_format and row['TextEncoding'] == 'UTF-8' and (row['ExportStatus'] == 'EXPORTED_LOCAL_ONLY'))
        require(row['ContentHashStatus'] == 'PENDING_EXTERNAL_HASH' and integer(row, 'ArchiveVersion') == 1)
    meta, _ = table(folder, job, 'fitmetadata', ('N_DesignColumns', 'N_Categories'))
    require(len(meta) == 1)
    meta = meta[0]
    p = integer(meta, 'N_DesignColumns')
    k = integer(meta, 'N_Categories')
    require(1 <= p <= 500 and 1 <= k <= 7)
    design_columns = ['RBCX' + str(i) for i in range(1, p + 1)]
    rows_by_role = {}
    for role in ROLES:
        fields = set(CONTEXT) | set(FIXED_FIELDS[role].split())
        if role in {'anchor_design', 'score_design', 'column_scale'}:
            fields.update(design_columns)
        if role == 'profile' and expected['Model'] == 'FULL':
            fields.update('Crystalloid_1 Crystalloid_24 Pressors_1 Pressors_24 Sedatives_1_bin Sedatives_24_bin'.split())
        rows, actual_fields = table(folder, job, role, fields)
        if role == 'convergence' and 'pdG' in actual_fields:
            fields.add('pdG')
        require(set(actual_fields) == fields)
        require(len(rows) == integer(manifest_map[role], 'RowCount'))
        require(len(actual_fields) == integer(manifest_map[role], 'ColumnCount'))
        for row in rows:
            require(all((row[key] == identity[key] for key in CONTEXT)))
            require(all((row[key] == expected[key] for key in ('Model', 'FactorName', 'VitalCode') if key in row)))
        require(encoding_matches(rows, numeric_format))
        rows_by_role[role] = rows
    require(meta['FitStatus'] == 'FIT_CHECKS_PASSED' and integer(meta, 'EngineRunChecksPassed') == 1)
    require(meta['ArchiveStatus'] == 'PENDING_MATRIX_VALIDATION' and meta['DDFMethod'] == identity['DFMethod'])
    df = number(meta, 'ResidualDF')
    require(df > 0)
    require(integer(meta, 'BeforeMinute') == -60 and integer(meta, 'AfterMinute') == 60)
    require(integer(meta, 'N_Used') > 0 and integer(meta, 'N_Patients') > 1)
    require(integer(meta, 'N_Used') + integer(meta, 'N_Excluded_Missing') == integer(meta, 'N_Scope'))
    available = validate_plan(rows_by_role, expected, fitted=True)
    status = rows_by_role['job_status'][0]
    for field in ('N_Scope', 'N_Used', 'N_Patients', 'N_Events'):
        require(integer(meta, field) == integer(status, field))
    require(meta['AdmissionCountStatus'] == status['AdmissionCountStatus'])
    require(validate_admission_count(meta, expected) == validate_admission_count(status, expected))
    require(integer(status, 'AvailableCategories') == k == len(available))
    cats = unique(rows_by_role['categories'], 'CategoryIndex')
    require(set(cats) == set(range(1, k + 1)))
    require({integer(row, 'CategoryCode'): index for index, row in cats.items()} == available)
    availability = {integer(row, 'CategoryCode'): row for row in rows_by_role['cat_availability']}
    for row in cats.values():
        planned = availability[integer(row, 'CategoryCode')]
        require(all((integer(row, field) == integer(planned, field) for field in ('N_Observations', 'N_Patients', 'N_Events'))))
    active_within = {integer(r, 'CategoryCodeA') for r in rows_by_role['contrast_plan'] if r['ContrastType'] == 'WITHIN' and integer(r, 'Active') == 1}
    active_pairs = {(integer(r, 'CategoryCodeA'), integer(r, 'CategoryCodeB')) for r in rows_by_role['contrast_plan'] if r['ContrastType'] == 'PAIRWISE' and integer(r, 'Active') == 1}
    require({integer(r, 'CategoryCodeA') for r in rows_by_role['within_changes']} == active_within)
    require({(integer(r, 'CategoryCodeA'), integer(r, 'CategoryCodeB')) for r in rows_by_role['pairwise']} == active_pairs)
    require(len(rows_by_role['pairwise']) == integer(rows_by_role['family_plan'][0], 'ActivePairs'))
    require(len(rows_by_role['profile']) == 1 and len(rows_by_role['column_scale']) == 1)
    require(all((number(rows_by_role['column_scale'][0], column) > 0 for column in design_columns)))
    knot_effects = {'TimeFromTransfusion': 'spl_time', 'PatientAge': 'spl_age', 'ICU_time': 'spl_icu'}
    if expected['Model'] == 'FULL':
        knot_effects.update(Crystalloid_1='spl_cryst1', Crystalloid_24='spl_cryst24', Pressors_1='spl_press1', Pressors_24='spl_press24')
    knots = rows_by_role['knots']
    require(len(knots) == (25 if expected['Model'] == 'FULL' else 13))
    require({row['VariableName'] for row in knots} == set(knot_effects))
    for variable, effect in knot_effects.items():
        group = [row for row in knots if row['VariableName'] == variable]
        count = 7 if variable == 'TimeFromTransfusion' else 3
        source = 'FIXED_TIME_SPECIFICATION' if count == 7 else 'REAL_COMPLETE_CASE_NATIVE_SAS'
        numbered = unique(group, 'KnotNumber')
        require(set(numbered) == set(range(1, count + 1)))
        values = []
        for index in range(1, count + 1):
            row = numbered[index]
            boundary = 'LOWER' if index == 1 else 'UPPER' if index == count else 'INTERNAL'
            require(row['EffectName'].lower() == effect and row['Basis'] == 'NATURALCUBIC')
            require(row['KnotSource'] == source and row['BoundaryRole'] == boundary and (integer(row, 'ExpectedKnots') == count))
            values.append(number(row, 'KnotValue'))
        require(bool((np.diff(values) > 0).all()))
        if count == 7:
            require(values == [-660, -360, -60, 0, 60, 360, 660])
    require(len(rows_by_role['solution']) == p and len(rows_by_role['fitstats']) > 0)
    require({r['Effect'].upper() for r in rows_by_role['solution']} == set(design_columns))
    coefficients = {row['Effect'].upper(): number(row, 'Estimate') for row in rows_by_role['solution']}
    score = unique(rows_by_role['score_design'], 'GridID')
    curve = unique(rows_by_role['trajectory'], 'GridID')
    require(set(score) == set(curve))
    ids = sorted(score)
    design = np.asarray([[number(score[i], column) for column in design_columns] for i in ids])
    means = np.asarray([number(curve[i], 'Predicted') for i in ids])
    fitted = design @ np.asarray([coefficients[column] for column in design_columns])
    scale = max(float(np.max(np.abs(means))), float(np.max(np.abs(fitted))), 1e-100)
    require(bool(np.allclose(fitted, means, rtol=1e-07, atol=1e-12 * scale)))
    require(len(rows_by_role['convergence']) == 1 and integer(rows_by_role['convergence'][0], 'Status') == 0)
    cov = rows_by_role['covparms']
    require(len(cov) == 2 and {r['CovParm'] for r in cov} == {'Intercept', 'Residual'})
    require(all((number(r, 'Estimate') > 0 if r['CovParm'] == 'Residual' else number(r, 'Estimate') >= 0 for r in cov)))
    infer = rows_by_role['inference_reference']
    require(len(infer) == 1)
    infer = infer[0]
    require(number(infer, 'Alpha') == 0.05 and number(infer, 'DF') == df)
    require(infer['DFReference'] == meta['DDFMethod'] and infer['CovarianceReference'] == meta['CovarianceModel'])
    critical = number(infer, 'CriticalValue')
    require(critical > 1.95)
    archive = validate_exchange(folder, job, k)
    for role in ('anchor_levels', 'anchor_diffs', 'within_changes', 'pairwise'):
        for row in rows_by_role[role]:
            require(number(row, 'DF') == df)
            _ci(row, critical)
    for row in rows_by_role['trajectory']:
        _ci(row, critical, 'Predicted')
    for role in ('within_changes', 'pairwise'):
        require(all((0 <= number(r, 'PValue') <= 1 for r in rows_by_role[role])))
    pairs = sorted(rows_by_role['pairwise'], key=lambda r: (number(r, 'PValue'), r['Label']))
    previous = 0.0
    for rank, row in enumerate(pairs, 1):
        previous = min(1, max(previous, (len(pairs) - rank + 1) * number(row, 'PValue')))
        require(integer(row, 'Rank') == rank and integer(row, 'FamilySize') == len(pairs))
        require(row['PAdjustment'] == 'Holm within family' and row['CIAdjustment'] == 'None: pointwise')
        _close(number(row, 'PValue_Holm'), previous, rtol=1e-12, atol=1e-15)
    anchor = unique(rows_by_role['anchor_design'], 'AnchorID')
    coordinates = {(integer(row, 'CategoryIndex'), integer(row, 'TimeFromTransfusion')): aid - 1 for aid, row in anchor.items()}

    def weights(terms):
        out = np.zeros(9 * k)
        for category, time, coefficient in terms:
            out[coordinates[category, time]] += coefficient
        return out
    if k > 1:
        require(len(rows_by_role['omnibus']) == 1 and len(rows_by_role['interaction_test']) == 1)
        endpoint = [weights([(c, 60, 1), (c, -60, -1), (1, 60, -1), (1, -60, 1)]) for c in range(2, k + 1)]
        _wald(endpoint, archive, rows_by_role['omnibus'][0], df)
        interaction = [weights([(c, t, 1), (c, 0, -1), (1, t, -1), (1, 0, 1)]) for c in range(2, k + 1) for t in (-660, -360, -60, 60, 360, 660)]
        _wald(interaction, archive, rows_by_role['interaction_test'][0], df)
    else:
        require(not rows_by_role['omnibus'] and (not rows_by_role['interaction_test']))
    fingerprints = {}
    for role, path in paths.items():
        require(_file_state(path) == before[role])
        fingerprints[role] = hashlib.sha256(path.read_bytes()).hexdigest()
        require(_file_state(path) == before[role])
    digest = hashlib.sha256(json.dumps(fingerprints, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'status': 'VALIDATED', 'protocol': 'RBC_MODEL_ARCHIVE_VALIDATION_V1', 'ScientificApproval': 'NOT_GRANTED', 'ArchiveContentDigest': digest, 'ValidationScope': 'IDENTITY_DESIGN_JOINT_COVARIANCE_ALL_GRID_SES_CONTRASTS_CI_HOLM_OMNIBUS', 'PValueValidation': 'SAS_ENGINE_FIXTURE_REQUIRED', 'FullRunReady': False}

def validate(folder: Path, job: str, expected: dict) -> dict:
    """Fixed feedback boundary: malformed cells cannot enter surfaced errors."""
    try:
        return _validate(folder, job, expected)
    except Exception:
        raise ExchangeError('MODEL_ARCHIVE_VALIDATION_FAILED') from None
