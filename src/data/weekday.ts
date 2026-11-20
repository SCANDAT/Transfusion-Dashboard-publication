import type { FitKey } from './release'
import type { TableRow } from './tables'

export const WEEKDAY_CODES = ['2', '3', '4', '5', '6'] as const
export const WEEKDAY_PROTOCOL = 'MONDAY_FRIDAY_IMMUTABLE_COMPANION_BUNDLE_V1' as const
export const WEEKDAY_CONTEXT_FIELDS = [
  'InferenceScope', 'CompanionProtocol', 'CompanionManifestSHA256', 'TargetSetID',
  'HolmFamilyID', 'MeanSolutionKind', 'CandidateMeanID', 'OriginalMeanOriginIsParentProvenanceOnly',
  'EndpointJointSourceSHA256', 'TrajectoryJointSourceSHA256',
] as const

export interface WeekdayBinding {
  readonly inferenceScope: 'MONDAY_FRIDAY'
  readonly companionManifestSha256: string
  readonly targetSetId: string
  readonly holmFamilyId: string
  readonly meanSolutionKind: 'ORIGINAL_FIT' | 'FIXED_COVARIANCE_GLS_RECOVERY'
  readonly candidateMeanId: string
}

export function isWeekdayPlan(codes: readonly string[]): boolean {
  return codes.join('/') === WEEKDAY_CODES.join('/')
}

function check(condition: unknown, code: string): asserts condition {
  if (!condition) throw new Error(code)
}

/** Check that the weekday estimate and its inference use the same mean solution. */
export function weekdayBinding(row: TableRow, factor: FitKey['factor']): WeekdayBinding | undefined {
  if (factor !== 'wdy_donation') {
    check(!WEEKDAY_CONTEXT_FIELDS.some(field => field in row), 'UNEXPECTED_WEEKDAY_BINDING')
    return undefined
  }
  check(row.InferenceScope === 'MONDAY_FRIDAY' && row.CompanionProtocol === WEEKDAY_PROTOCOL,
    'WEEKDAY_COMPANION_REQUIRED')
  for (const field of ['CompanionManifestSHA256', 'EndpointJointSourceSHA256', 'TrajectoryJointSourceSHA256']) {
    check(typeof row[field] === 'string' && /^[a-f0-9]{64}$/.test(row[field] as string), 'WEEKDAY_SOURCE_BINDING_INVALID')
  }
  for (const field of ['TargetSetID', 'HolmFamilyID', 'CandidateMeanID']) {
    check(typeof row[field] === 'string' && /^[A-Za-z0-9][A-Za-z0-9_.-]{0,179}$/.test(row[field] as string),
      'WEEKDAY_IDENTITY_INVALID')
  }
  check(row.MeanSolutionKind === 'ORIGINAL_FIT' || row.MeanSolutionKind === 'FIXED_COVARIANCE_GLS_RECOVERY',
    'WEEKDAY_MEAN_SOLUTION_INVALID')
  if (row.MeanSolutionKind === 'ORIGINAL_FIT') {
    check(row.CandidateMeanID === 'NONE' && row.OriginalMeanOriginIsParentProvenanceOnly === 0,
      'WEEKDAY_MEAN_PAIRING_INVALID')
  } else {
    check(row.CandidateMeanID !== 'NONE' && row.OriginalMeanOriginIsParentProvenanceOnly === 1,
      'WEEKDAY_MEAN_PAIRING_INVALID')
  }
  return Object.freeze({ inferenceScope: 'MONDAY_FRIDAY',
    companionManifestSha256: row.CompanionManifestSHA256 as string,
    targetSetId: row.TargetSetID as string, holmFamilyId: row.HolmFamilyID as string,
    meanSolutionKind: row.MeanSolutionKind, candidateMeanId: row.CandidateMeanID as string })
}
