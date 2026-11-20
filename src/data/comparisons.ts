import { isWeekdayPlan, weekdayBinding, WEEKDAY_CONTEXT_FIELDS, type WeekdayBinding } from './weekday'
import { type FitPlan } from './release'
import { numericCell, tableRows, textCell, type ResultTable, type TableRow } from './tables'

export class ComparisonValidationError extends Error {
  constructor(readonly code: string) { super(code); this.name = 'ComparisonValidationError' }
}
function check(value: unknown, code: string): asserts value {
  if (!value) throw new ComparisonValidationError(code)
}
function finite(row: TableRow, field: string): number {
  const value = numericCell(row, field)
  check(value !== null, 'COMPARISON_VALUE_UNAVAILABLE')
  return value
}
function probability(row: TableRow, field: string): number {
  const value = finite(row, field)
  check(value >= 0 && value <= 1, 'COMPARISON_PROBABILITY_RANGE')
  return value
}
function close(a: number, b: number): boolean {
  return Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b))
}
const REQUIRED_IDENTITY = [
  'RunId', 'FitId', 'DesignId', 'ProfileId', 'JobID', 'InputSnapshotId',
  'CodeHash', 'ConfigHash', 'CohortMode', 'PopulationId', 'ScalarDFMethod', 'JointDFMethod',
] as const
const OTHER_CONTEXT = [
  'AnalysisSpecId', 'DFMethod', 'SubjectKeySource', 'SubjectAlias', 'DesignIdentityKind',
  'ProfileIdentityKind', 'InferenceStatus', 'WorkingDFMethod', 'WorkingInferenceStatus',
  'Scope', 'CovarianceMethod', 'WorkingTarget', 'CR2Protocol', 'CR2ArchiveID',
  'CalibrationDomain', 'StructuralCertificate', 'BindingVersion', 'WorkingBindingVersion',
  'TargetCalibrationVerified', 'AllCoefficientsCalibrated', ...WEEKDAY_CONTEXT_FIELDS,
] as const

export interface CategoryComparison {
  readonly code: string
  readonly estimate: number | null
  readonly lower: number | null
  readonly upper: number | null
  readonly stdErr: number | null
  readonly df: number | null
  readonly pValue: number | null
  readonly status: 'COMPUTED' | 'UNAVAILABLE'
}
export interface PairComparison {
  readonly a: string
  readonly b: string
  readonly estimate: number
  readonly lower: number
  readonly upper: number
  readonly stdErr: number
  readonly df: number
  readonly pValue: number
  readonly holmP: number
  readonly rank: number
  readonly familyId: string
  readonly status: 'COMPUTED'
}
export type JointStatus = 'COMPUTED' | 'LOW_EFFECTIVE_DF' | 'INSUFFICIENT_EFFECTIVE_DF'
  | 'NOT_APPLICABLE_SINGLE_CATEGORY' | 'MOMENT_PRECISION_UNRESOLVED' | 'DF2_SIGN_UNRESOLVED'
export interface JointComparison {
  readonly kind: 'endpoint' | 'trajectory'
  readonly pValue: number | null
  readonly df1: number | null
  readonly df2: number | null
  readonly fValue: number | null
  readonly status: JointStatus
  readonly jointStatus: number
}
export interface ComponentComparison {
  readonly weekday?: WeekdayBinding
  readonly plannedCategoryCodes: readonly string[]
  readonly activeCategoryCodes: readonly string[]
  readonly categories: readonly CategoryComparison[]
  /** Contrasts retain the reported order and A-minus-B direction. */
  readonly pairs: readonly PairComparison[]
  readonly unavailablePairs: readonly { readonly a: string; readonly b: string; readonly status: 'UNAVAILABLE' }[]
  readonly tests: readonly JointComparison[]
  readonly pairFamilyId: string | null
  readonly direction: 'A_MINUS_B'
  readonly pairwisePAdjustment: 'HOLM_WITHIN_FROZEN_FIT_FAMILY'
  readonly confidenceIntervals: 'POINTWISE_UNADJUSTED'
}

function category(row: TableRow, field: string, planned: ReadonlySet<string>): string {
  const value = finite(row, field)
  check(Number.isInteger(value) && planned.has(String(value)), 'CATEGORY_OUTSIDE_PLAN')
  return String(value)
}
function scalar(row: TableRow, role: 'WITHIN' | 'PAIRWISE') {
  check(textCell(row, 'TargetRole') === role
    && finite(row, 'TargetKind') === (role === 'WITHIN' ? 3 : 4), 'SCALAR_ROLE_MISMATCH')
  check(textCell(row, 'NumericStatus') === 'COMPUTED'
    && finite(row, 'ContrastStatus') === 0, 'UNSUPPORTED_ACTIVE_COMPARISON')
  check(finite(row, 'BaselineMinute') === -60 && finite(row, 'EndpointMinute') === 60, 'COMPARISON_TIME_MISMATCH')
  check(textCell(row, 'CIAdjustment') === 'None: pointwise', 'COMPARISON_CI_METHOD_MISMATCH')
  const estimate = finite(row, 'Estimate')
  const lower = finite(row, 'Lower')
  const upper = finite(row, 'Upper')
  const stdErr = finite(row, 'StdErr')
  const df = finite(row, 'DF')
  check(lower <= estimate && estimate <= upper && stdErr > 0 && df >= 1 - 1e-8, 'COMPARISON_INTERVAL_INVALID')
  return { estimate, lower, upper, stdErr, df, pValue: probability(row, 'Probt') }
}

function identity(tables: readonly ResultTable[], rows: readonly (readonly TableRow[])[]): string {
  const first = tables[0]
  check(first !== undefined, 'COMPARISON_TABLE_MISSING')
  const allRows = tables.flatMap((table, index) => {
    const values = rows[index]
    check(values !== undefined, 'COMPARISON_TABLE_MISSING')
    return values.length > 0 ? values : [table.context]
  })
  const firstRow = allRows[0]
  check(firstRow !== undefined, 'COMPARISON_IDENTITY_MISSING')
  const fields = [...REQUIRED_IDENTITY, ...OTHER_CONTEXT.filter(field => allRows.some(row => field in row))]
  for (const table of tables) {
    check(table.releaseId === first.releaseId
      && table.key.population === first.key.population && table.key.model === first.key.model
      && table.key.factor === first.key.factor && table.key.outcome === first.key.outcome, 'COMPARISON_FIT_MISMATCH')
  }
  for (const row of allRows) {
    for (const field of fields) {
      check(Object.prototype.hasOwnProperty.call(row, field)
        && Object.prototype.hasOwnProperty.call(firstRow, field)
        && row[field] === firstRow[field], 'COMPARISON_ORIGINAL_IDENTITY_MISMATCH')
    }
    check(textCell(row, 'ScalarDFMethod') === 'CONTRAST_SATTERTHWAITE'
      && textCell(row, 'JointDFMethod') === 'HTZ', 'COMPARISON_INFERENCE_METHOD_MISMATCH')
  }
  return textCell(firstRow, 'FitId')
}

/** Read the fitted contrasts and their reported multiplicity adjustments. */
export function readComparison(
  within: ResultTable, pairwise: ResultTable, joint: ResultTable, plan: FitPlan,
): ComponentComparison {
  check(within.role === 'within' && pairwise.role === 'pairwise' && joint.role === 'joint', 'COMPARISON_ROLE_MISMATCH')
  check(['within', 'pairwise', 'joint'].every(role => plan.requestedRoles.some(value => value === role)), 'COMPARISON_PLAN_ROLES_MISSING')
  const planned = new Set(plan.categoryCodes)
  check(planned.size > 0 && planned.size === plan.categoryCodes.length
    && plan.categoryCodes.every(code => /^(0|[1-9][0-9]*)$/.test(code)), 'COMPARISON_CATEGORY_PLAN_INVALID')
  const withinRows = tableRows(within), pairRows = tableRows(pairwise), jointRows = tableRows(joint)
  const fitId = identity([within, pairwise, joint], [withinRows, pairRows, jointRows])
  const weekday = weekdayBinding(within.context, within.key.factor)
  for (const table of [pairwise, joint]) weekdayBinding(table.context, table.key.factor)
  if (weekday) check(isWeekdayPlan(plan.categoryCodes), 'WEEKDAY_COMPARISON_SCOPE')
  const active = new Map<string, CategoryComparison>()
  for (const row of withinRows) {
    const code = category(row, 'CategoryCodeA', planned)
    check(!active.has(code), 'DUPLICATE_WITHIN_CATEGORY')
    const stats = scalar(row, 'WITHIN')
    check(textCell(row, 'PAdjustment') === 'NONE' && textCell(row, 'FamilyID') === 'NONE', 'WITHIN_ADJUSTMENT_MISMATCH')
    active.set(code, Object.freeze({ code, ...stats, status: 'COMPUTED' }))
  }
  check(active.size > 0, 'NO_ACTIVE_COMPARISON_CATEGORY')
  if (weekday) check(active.size === 5, 'WEEKDAY_WITHIN_FAMILY_INCOMPLETE')
  const familyId = weekday?.holmFamilyId ?? fitId + '.PAIRWISE'
  const pairKeys = new Set<string>()
  const ranks = new Map<number, PairComparison>()
  const pairs = pairRows.map(row => {
    const a = category(row, 'CategoryCodeA', planned), b = category(row, 'CategoryCodeB', planned)
    check(Number(a) < Number(b) && active.has(a) && active.has(b), 'INVALID_PAIR_DIRECTION_OR_SCOPE')
    const pairKey = JSON.stringify([a, b])
    check(!pairKeys.has(pairKey), 'DUPLICATE_PAIR')
    pairKeys.add(pairKey)
    const stats = scalar(row, 'PAIRWISE')
    check(textCell(row, 'FamilyID') === familyId
      && textCell(row, 'PAdjustment') === (weekday ? 'Holm within amended fixed family10' : 'Holm within frozen family'), 'PAIR_FAMILY_MISMATCH')
    const rawP = probability(row, 'PValue'), holmP = probability(row, 'PValue_Holm')
    const rank = finite(row, 'Rank')
    check(rawP === stats.pValue && holmP + 1e-14 >= rawP, 'PAIR_P_VALUE_INVALID')
    check(Number.isInteger(rank) && rank >= 1 && rank <= pairRows.length && !ranks.has(rank), 'PAIR_RANK_INVALID')
    const left = active.get(a)?.estimate, right = active.get(b)?.estimate
    check(left !== null && left !== undefined && right !== null && right !== undefined
      && close(stats.estimate, left - right), 'PAIR_POINT_DIRECTION_MISMATCH')
    const result: PairComparison = Object.freeze({ a, b, ...stats, pValue: rawP, holmP, rank, familyId, status: 'COMPUTED' })
    ranks.set(rank, result)
    return result
  })
  if (weekday) check(pairs.length === 10, 'WEEKDAY_PAIR_FAMILY_INCOMPLETE')
  const activeCodes = [...active.keys()]
  check(pairs.length === active.size * (active.size - 1) / 2, 'INCOMPLETE_ACTIVE_PAIR_FAMILY')
  for (let index = 1; index <= ranks.size; index += 1) {
    const current = ranks.get(index), previous = ranks.get(index - 1)
    check(current !== undefined, 'PAIR_RANK_INVALID')
    if (previous) check(previous.pValue <= current.pValue + 1e-14
      && previous.holmP <= current.holmP + 1e-14, 'PAIR_P_VALUES_NOT_MONOTONE')
  }
  const jointLabels: readonly JointStatus[] = [
    'COMPUTED', 'LOW_EFFECTIVE_DF', 'INSUFFICIENT_EFFECTIVE_DF',
    'NOT_APPLICABLE_SINGLE_CATEGORY', 'MOMENT_PRECISION_UNRESOLVED', 'DF2_SIGN_UNRESOLVED',
  ]
  const testKinds = new Set<string>()
  const tests = jointRows.map(row => {
    const role = textCell(row, 'TestRole')
    const endpointRole = weekday ? 'MONDAY_FRIDAY_ENDPOINT_CHANGE_EQUALITY' : 'ENDPOINT_HETEROGENEITY'
    const trajectoryRole = weekday ? 'MONDAY_FRIDAY_TRAJECTORY_INTERACTION' : 'WHOLE_TRAJECTORY_INTERACTION'
    check(role === endpointRole || role === trajectoryRole, 'UNKNOWN_JOINT_TEST')
    const kind = role === endpointRole ? 'endpoint' : 'trajectory'
    check(!testKinds.has(kind), 'DUPLICATE_JOINT_TEST'); testKinds.add(kind)
    check(finite(row, 'TestIndex') === (kind === 'endpoint' ? 1 : 2), 'JOINT_TEST_INDEX_MISMATCH')
    const jointStatus = finite(row, 'JointStatus'), status = jointLabels[jointStatus]
    check(Number.isInteger(jointStatus) && status !== undefined
      && textCell(row, 'NumericStatus') === status, 'JOINT_STATUS_MISMATCH')
    const df1 = numericCell(row, 'DF1'), df2 = numericCell(row, 'DF2')
    const fValue = numericCell(row, 'FValue'), pValue = numericCell(row, 'ProbF')
    if (jointStatus <= 1) {
      check(active.size > 1 && df1 !== null && df1 > 0 && df2 !== null && df2 > 0
        && fValue !== null && fValue >= 0 && pValue !== null && pValue >= 0 && pValue <= 1, 'INVALID_AVAILABLE_JOINT')
    } else {
      check(fValue === null && pValue === null, 'UNAVAILABLE_JOINT_HAS_INFERENCE')
      if (jointStatus === 3) check(active.size === 1 && df1 === null && df2 === null, 'SINGLE_CATEGORY_JOINT_MISMATCH')
      else {
        check(active.size > 1 && df1 !== null && df1 > 0, 'UNAVAILABLE_JOINT_SCOPE_MISMATCH')
        if (jointStatus === 2) check(df2 !== null && df2 <= 0, 'INSUFFICIENT_JOINT_DF_MISMATCH')
        if (jointStatus === 5) check(df2 !== null, 'UNRESOLVED_JOINT_DF_MISSING')
      }
    }
    return Object.freeze({ kind, pValue, df1, df2, fValue, status, jointStatus }) as JointComparison
  })
  check(testKinds.size === 2, 'INCOMPLETE_JOINT_TESTS')
  const categories = plan.categoryCodes.map(code => active.get(code) ?? Object.freeze({
    code, estimate: null, lower: null, upper: null, stdErr: null, df: null, pValue: null, status: 'UNAVAILABLE' as const,
  }))
  const unavailablePairs: { a: string; b: string; status: 'UNAVAILABLE' }[] = []
  for (const a of plan.categoryCodes) for (const b of plan.categoryCodes) {
    if (Number(a) < Number(b) && (!active.has(a) || !active.has(b))) unavailablePairs.push({ a, b, status: 'UNAVAILABLE' })
  }
  return Object.freeze({
    ...(weekday ? { weekday } : {}),
    plannedCategoryCodes: Object.freeze([...plan.categoryCodes]), activeCategoryCodes: Object.freeze(activeCodes),
    categories: Object.freeze(categories), pairs: Object.freeze(pairs),
    unavailablePairs: Object.freeze(unavailablePairs.map(pair => Object.freeze(pair))),
    tests: Object.freeze(tests), pairFamilyId: pairs.length ? familyId : null,
    direction: 'A_MINUS_B', pairwisePAdjustment: 'HOLM_WITHIN_FROZEN_FIT_FAMILY',
    confidenceIntervals: 'POINTWISE_UNADJUSTED',
  })
}

