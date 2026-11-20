import { isWeekdayPlan, weekdayBinding, WEEKDAY_CONTEXT_FIELDS } from './weekday'
import {
  AUTHORITATIVE_ROLES, FACTORS, MODELS, OUTCOMES, POPULATIONS,
  getAuthoritativeReference, type AuthoritativeRole, type FitKey, type ValidatedRelease,
} from './release'

export const TABLE_SCHEMA = 'transfusion-dashboard/table-v1' as const
export type TableCell = string | number | null
export type TableRow = Readonly<Record<string, TableCell>>

/** Lossless column split: constant original fields in context, variable fields in rows. */
export interface ResultTable {
  readonly schemaVersion: typeof TABLE_SCHEMA
  readonly releaseId: string
  readonly key: FitKey
  readonly role: AuthoritativeRole
  /** Digest of the source table; the manifest separately binds this JSON asset's bytes. */
  readonly sourceSha256: string
  readonly context: TableRow
  readonly columns: readonly string[]
  readonly rows: readonly (readonly TableCell[])[]
}

export type TableErrorCode =
  | 'INVALID_TABLE_SHAPE' | 'UNSUPPORTED_TABLE_SCHEMA' | 'TABLE_IDENTITY_MISMATCH'
  | 'INVALID_SOURCE_HASH' | 'INVALID_COLUMN' | 'DUPLICATE_COLUMN' | 'CONTEXT_COLUMN_OVERLAP'
  | 'INVALID_CELL' | 'ROW_LENGTH_MISMATCH' | 'MISSING_IDENTITY_FIELD'
  | 'INVALID_ORIGINAL_IDENTITY' | 'MIXED_ORIGINAL_IDENTITY' | 'ORIGINAL_SCOPE_MISMATCH'
  | 'REQUIRED_FIELD_MISSING' | 'NUMERIC_FIELD_REQUIRED' | 'TEXT_FIELD_REQUIRED'
  | 'TRAJECTORY_ROLE_REQUIRED' | 'DUPLICATE_TRAJECTORY_POINT' | 'INVALID_TRAJECTORY_COORDINATE'
  | 'INVALID_INTERVAL_ORDER' | 'UNSUPPORTED_TRAJECTORY_STATUS'

export class TableValidationError extends Error {
  constructor(readonly code: TableErrorCode) {
    super(code)
    this.name = 'TableValidationError'
  }
}

function check(value: unknown, code: TableErrorCode): asserts value {
  if (!value) throw new TableValidationError(code)
}

function object(value: unknown): Record<string, unknown> {
  check(typeof value === 'object' && value !== null && !Array.isArray(value), 'INVALID_TABLE_SHAPE')
  return value as Record<string, unknown>
}

function exact(value: unknown, names: readonly string[]): Record<string, unknown> {
  const input = object(value)
  check(Object.keys(input).length === names.length
    && names.every(name => Object.prototype.hasOwnProperty.call(input, name)), 'INVALID_TABLE_SHAPE')
  return input
}

function cell(value: unknown): TableCell {
  check(value === null || typeof value === 'string'
    || (typeof value === 'number' && Number.isFinite(value)), 'INVALID_CELL')
  return value
}

function column(value: unknown): string {
  check(typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(value)
    && !['__proto__', 'prototype', 'constructor'].includes(value), 'INVALID_COLUMN')
  return value
}

function sameKey(a: FitKey, b: FitKey): boolean {
  return a.population === b.population && a.model === b.model
    && a.factor === b.factor && a.outcome === b.outcome
}

function parseKey(value: unknown): FitKey {
  const key = exact(value, ['population', 'model', 'factor', 'outcome'])
  check(POPULATIONS.includes(key.population as FitKey['population'])
    && MODELS.includes(key.model as FitKey['model'])
    && FACTORS.includes(key.factor as FitKey['factor'])
    && OUTCOMES.includes(key.outcome as FitKey['outcome']), 'TABLE_IDENTITY_MISMATCH')
  return Object.freeze(key) as unknown as FitKey
}

const ID_FIELDS = ['RunId', 'FitId', 'DesignId', 'ProfileId', 'JobID'] as const
const HASH_FIELDS = ['InputSnapshotId', 'CodeHash', 'ConfigHash'] as const
const SCOPE_FIELDS = ['CohortMode', 'PopulationId'] as const
const REQUIRED_IDENTITY = [...ID_FIELDS, ...HASH_FIELDS, ...SCOPE_FIELDS] as const

function originalIdentity(row: TableRow, release: ValidatedRelease, key: FitKey): TableRow {
  const identity: Record<string, TableCell> = Object.create(null) as Record<string, TableCell>
  for (const field of REQUIRED_IDENTITY) {
    check(Object.prototype.hasOwnProperty.call(row, field), 'MISSING_IDENTITY_FIELD')
    const value = row[field]
    check(typeof value === 'string' && value.length > 0, 'INVALID_ORIGINAL_IDENTITY')
    identity[field] = value
  }
  check(typeof row.RunId === 'string' && /^[a-f0-9]{32}$/.test(row.RunId), 'INVALID_ORIGINAL_IDENTITY')
  for (const field of ID_FIELDS.filter(field => field !== 'RunId')) {
    check(typeof row[field] === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(row[field]), 'INVALID_ORIGINAL_IDENTITY')
  }
  for (const field of HASH_FIELDS) {
    check(typeof row[field] === 'string' && /^[a-f0-9]{64}$/.test(row[field]), 'INVALID_ORIGINAL_IDENTITY')
  }
  check(row.CohortMode === release.manifest.datasetKind && row.PopulationId === key.population, 'ORIGINAL_SCOPE_MISMATCH')
  if ('Model' in row) check(row.Model === key.model, 'ORIGINAL_SCOPE_MISMATCH')
  if ('VitalCode' in row) check(row.VitalCode === key.outcome, 'ORIGINAL_SCOPE_MISMATCH')
  if ('FactorName' in row) check(row.FactorName === key.factor
    || (key.factor === 'MAIN' && row.FactorName === 'NONE'), 'ORIGINAL_SCOPE_MISMATCH')
  return identity
}

function reconstruct(table: ResultTable, values: readonly TableCell[]): TableRow {
  const row: Record<string, TableCell> = Object.assign(Object.create(null), table.context) as Record<string, TableCell>
  table.columns.forEach((name, index) => {
    const value = values[index]
    check(value !== undefined, 'ROW_LENGTH_MISMATCH')
    row[name] = value
  })
  return Object.freeze(row)
}

/** Check the table schema and its relationship to the selected fit. */
export function validateResultTable(
  value: unknown, release: ValidatedRelease, requestedKey: FitKey, requestedRole: AuthoritativeRole,
): ResultTable {
  getAuthoritativeReference(release, requestedKey, requestedRole)
  const input = exact(value, ['schemaVersion', 'releaseId', 'key', 'role', 'sourceSha256', 'context', 'columns', 'rows'])
  check(input.schemaVersion === TABLE_SCHEMA, 'UNSUPPORTED_TABLE_SCHEMA')
  const key = parseKey(input.key)
  check(input.releaseId === release.manifest.releaseId && sameKey(key, requestedKey)
    && input.role === requestedRole && AUTHORITATIVE_ROLES.includes(input.role as AuthoritativeRole), 'TABLE_IDENTITY_MISMATCH')
  check(typeof input.sourceSha256 === 'string' && /^[a-f0-9]{64}$/.test(input.sourceSha256), 'INVALID_SOURCE_HASH')
  const inputContext = object(input.context)
  const context: Record<string, TableCell> = Object.create(null) as Record<string, TableCell>
  for (const [name, value] of Object.entries(inputContext)) context[column(name)] = cell(value)
  check(Array.isArray(input.columns) && Array.isArray(input.rows), 'INVALID_TABLE_SHAPE')
  const columns = input.columns.map(column)
  check(new Set(columns).size === columns.length, 'DUPLICATE_COLUMN')
  check(columns.every(name => !Object.prototype.hasOwnProperty.call(context, name)), 'CONTEXT_COLUMN_OVERLAP')
  const rows = input.rows.map(value => {
    check(Array.isArray(value) && value.length === columns.length, 'ROW_LENGTH_MISMATCH')
    return Object.freeze(value.map(cell))
  })
  const table: ResultTable = Object.freeze({
    schemaVersion: TABLE_SCHEMA, releaseId: release.manifest.releaseId, key,
    role: requestedRole, sourceSha256: input.sourceSha256,
    context: Object.freeze(context), columns: Object.freeze(columns), rows: Object.freeze(rows),
  })
  const companion = weekdayBinding(table.context, key.factor)
  if (companion) {
    const plan = release.manifest.jobs.find(job => sameKey(job.key, key))?.plan
    check(plan && isWeekdayPlan(plan.categoryCodes), 'ORIGINAL_SCOPE_MISMATCH')
  }
  let identity: TableRow | undefined
  // An empty table still identifies its fit in the context fields.
  if (rows.length === 0) originalIdentity(table.context, release, key)
  for (const values of rows) {
    const row = reconstruct(table, values)
    const observed = originalIdentity(row, release, key)
    if (companion) {
      weekdayBinding(row, key.factor)
      check(WEEKDAY_CONTEXT_FIELDS.every(field => row[field] === table.context[field]), 'MIXED_ORIGINAL_IDENTITY')
      if (table.role === 'levels' || table.role === 'changes' || table.role === 'within' || table.role === 'pairwise') {
        check(typeof row.CategoryCodeA === 'number' && Number.isInteger(row.CategoryCodeA)
          && row.CategoryCodeA >= 2 && row.CategoryCodeA <= 6, 'ORIGINAL_SCOPE_MISMATCH')
      }
    }
    if (identity === undefined) identity = observed
    else check(REQUIRED_IDENTITY.every(field => identity?.[field] === observed[field]), 'MIXED_ORIGINAL_IDENTITY')
  }
  return table
}

export function tableRows(table: ResultTable): readonly TableRow[] {
  return Object.freeze(table.rows.map(values => reconstruct(table, values)))
}

export function numericCell(row: TableRow, field: string): number | null {
  check(Object.prototype.hasOwnProperty.call(row, field), 'REQUIRED_FIELD_MISSING')
  const value = row[field]
  check(value === null || (typeof value === 'number' && Number.isFinite(value)), 'NUMERIC_FIELD_REQUIRED')
  return value
}

export function textCell(row: TableRow, field: string): string {
  check(Object.prototype.hasOwnProperty.call(row, field), 'REQUIRED_FIELD_MISSING')
  const value = row[field]
  check(typeof value === 'string' && value.length > 0, 'TEXT_FIELD_REQUIRED')
  return value
}

export interface TrajectoryPoint {
  readonly category: number
  readonly time: number
  readonly estimate: number | null
  readonly lower: number | null
  readonly upper: number | null
  readonly numericStatus: string
  readonly contrastStatus: number | null
}

/** Every grid point survives, including missing estimates and unavailable intervals. */
export function trajectoryRows(table: ResultTable): readonly TrajectoryPoint[] {
  check(table.role === 'levels' || table.role === 'changes', 'TRAJECTORY_ROLE_REQUIRED')
  const seen = new Set<string>()
  const points = tableRows(table).map(row => {
    const category = numericCell(row, 'CategoryCodeA')
    const time = numericCell(row, 'TimeFromTransfusion')
    check(category !== null && time !== null && Number.isInteger(category)
      && Number.isInteger(time) && time >= -720 && time <= 720, 'INVALID_TRAJECTORY_COORDINATE')
    const pointKey = JSON.stringify([category, time])
    check(!seen.has(pointKey), 'DUPLICATE_TRAJECTORY_POINT')
    seen.add(pointKey)
    const point = Object.freeze({
      category, time, estimate: numericCell(row, 'Estimate'),
      lower: numericCell(row, 'Lower'), upper: numericCell(row, 'Upper'),
      numericStatus: textCell(row, 'NumericStatus'), contrastStatus: numericCell(row, 'ContrastStatus'),
    })
    if (point.estimate !== null) {
      check(hasUsableEstimate(point), 'UNSUPPORTED_TRAJECTORY_STATUS')
      if (point.numericStatus === 'BASELINE_ZERO') {
        check(table.role === 'changes' && point.time === -60 && point.estimate === 0,
          'UNSUPPORTED_TRAJECTORY_STATUS')
      }
    }
    if (point.lower !== null && point.upper !== null) {
      check(point.lower <= point.upper, 'INVALID_INTERVAL_ORDER')
      if (point.estimate !== null) check(point.lower <= point.estimate && point.estimate <= point.upper, 'INVALID_INTERVAL_ORDER')
    }
    return point
  })
  return Object.freeze(points.sort((a, b) => a.category - b.category || a.time - b.time))
}

export function hasUsableEstimate(point: TrajectoryPoint): boolean {
  if (point.estimate === null) return false
  return (point.numericStatus === 'COMPUTED' && point.contrastStatus === 0)
    || (point.numericStatus === 'BASELINE_ZERO' && point.contrastStatus === 2 && point.estimate === 0)
    || (point.numericStatus === 'MOMENT_PRECISION_UNRESOLVED' && point.contrastStatus === 4)
}

export function hasUsableBand(point: TrajectoryPoint): boolean {
  if (point.estimate === null || point.lower === null || point.upper === null) return false
  if (point.numericStatus === 'BASELINE_ZERO') {
    return point.contrastStatus === 2 && point.estimate === 0 && point.lower === 0 && point.upper === 0
  }
  return point.contrastStatus === 0
    && point.numericStatus === 'COMPUTED'
}

/** Split at missing cells, category boundaries and gaps in the integer-minute grid. */
export function trajectorySegments(
  points: readonly TrajectoryPoint[], part: 'estimate' | 'band' = 'estimate',
): readonly (readonly TrajectoryPoint[])[] {
  const segments: TrajectoryPoint[][] = []
  let current: TrajectoryPoint[] = []
  let previous: TrajectoryPoint | undefined
  for (const point of points) {
    const usable = hasUsableEstimate(point) && (part === 'estimate' || hasUsableBand(point))
    const adjacent = previous !== undefined && previous.category === point.category && point.time === previous.time + 1
    if (!usable || !adjacent) {
      if (current.length > 0) segments.push(current)
      current = []
    }
    if (usable) current.push(point)
    previous = point
  }
  if (current.length > 0) segments.push(current)
  return Object.freeze(segments.map(segment => Object.freeze(segment)))
}


