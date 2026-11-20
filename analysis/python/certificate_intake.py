"""Load the arithmetic error bounds associated with a fitted model."""
import re
import numpy as np
from certificate_archive_schema import descriptor_from_context, validate_contractions
ALIASES = {'moment_error': 'si_moment_error', 'scalar_weights': 'si_scalar_weights', 'scalar_certificate': 'si_scalar_certificate', 'joint_weights': 'joint_weights', 'joint_certificate': 'joint_certificate'}

def intake_certificate(tables, identity, expected, *, h, k, moment, numeric_format, decimal_replay=None):
    """decimal_replay: optional DecimalReplayRunner handed through unchanged to
    validate_contractions; it only ever receives fast-inconclusive targets."""
    if numeric_format != 'HEX16_IEEE754':
        raise ValueError('CERTIFICATE_EXACT_TRANSPORT_REQUIRED')
    source = expected.get('ConstructionSourceSHA256')
    if not isinstance(source, str) or not re.fullmatch('[0-9a-f]{64}', source):
        raise ValueError('CERTIFICATE_TRUSTED_CLOSURE_REQUIRED')
    count = 2 * 1441 * k + k + k * (k - 1) // 2
    targets = list(range(1, count + 1))
    tests = [] if k == 1 else [dict(TestIndex=1, ConstraintIndices=list(range(1, k))), dict(TestIndex=2, ConstraintIndices=list(range(1, 6 * (k - 1) + 1)))]
    trusted = dict(RunId=expected['RunId'], FitId=expected['FitId'], Scope=identity['Scope'], ConstructionSourceSHA256=source, SpanDimension=h, MomentDimension=h * (h + 1) // 2, TargetIndices=targets, Tests=tests)
    context = dict(tables['certificate_context'].row(), RunId=identity['RunId'], FitId=identity['FitId'], Scope=identity['Scope'])
    descriptor = descriptor_from_context(context, target_indices=targets, tests=tests, expected=trusted)
    payload = {alias: [tables[role].row(i) for i in range(tables[role].n)] for alias, role in ALIASES.items()}
    report = validate_contractions(descriptor, payload, moment, expected=trusted, decimal_replay=decimal_replay)
    scalar = {int(row['TargetIndex']): row for row in payload['scalar_certificate']}
    scalar_weights = {int(row['TargetIndex']): np.array([row['COL' + str(i)] for i in range(1, h + 1)], dtype=float) for row in payload['scalar_weights']}
    joint = {int(row['TestIndex']): row for row in payload['joint_certificate']}
    joint_weights = {(int(row['TestIndex']), int(row['ConstraintIndex'])): np.array([row['COL' + str(i)] for i in range(1, h + 1)], dtype=float) for row in payload['joint_weights']}
    return dict(Report=report, Descriptor=descriptor, Scalars=scalar, ScalarWeights=scalar_weights, Joints=joint, JointWeights=joint_weights)
