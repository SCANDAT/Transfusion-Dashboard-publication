import { OUTCOMES, validateReleaseManifest, type ArtifactReference, type ValidatedRelease } from './release'

export const LOESS_SCHEMA = 'transfusion-dashboard/loess-v1'
export const LOESS_SERIES_SCHEMA = 'transfusion-dashboard/loess-series-v2'
const FIRST_SERIES_SCHEMA = 'transfusion-dashboard/loess-series-v1'
export interface ArchivedCurveFormat {
  coreManifestSha256: string
  methodAdoptionStatus: string
  nativeUnitStatus: string
}
type SeriesFormat =
  | { schemaVersion: typeof LOESS_SERIES_SCHEMA; methodAdoptionStatus: 'DIRECT_DEGREE2_LOESS'; unitStatus: 'SOURCE_UNIT_UNCONFIRMED' | 'STANDARDIZED_GLOBAL_SD' }
  | { schemaVersion: typeof FIRST_SERIES_SCHEMA; methodAdoptionStatus: string; unitStatus: string }
export const LOESS_SCALES = ['native', 'standardized'] as const
export const LOESS_FIT_STATUSES = ['DIRECT_COMPLETED', 'UNAVAILABLE_NO_INPUT', 'UNAVAILABLE_ZERO_OR_UNDEFINED_SCALE', 'INSUFFICIENT_SUPPORT'] as const
export type LoessScale = typeof LOESS_SCALES[number]
export type LoessOutcome = typeof OUTCOMES[number]
export type LoessFitStatus = typeof LOESS_FIT_STATUSES[number]
export interface LoessEntry { outcome: LoessOutcome; spanPercent: number; scale: LoessScale; fitStatus: LoessFitStatus; file: ArtifactReference }
export interface LoessManifest {
  schemaVersion: typeof LOESS_SCHEMA; releaseId: string; coreManifestSha256: string
  datasetKind: ValidatedRelease['manifest']['datasetKind']; diagnosticOnly: boolean; scientificApproved: boolean; publicationApproved: boolean
  population: 'PRIMARY'; methodId: 'DIRECT_LINEAR_DISPLAY_V1'; defaultSpanPercent: 30; series: readonly LoessEntry[]
}
export interface ValidatedLoess { manifest: LoessManifest; release: ValidatedRelease }
export const AVAILABLE_LOESS_POINTS = ['AVAILABLE_EXACT_KNOT', 'AVAILABLE_LINEAR_FROM_DIRECT'] as const
const pointStatuses = [...AVAILABLE_LOESS_POINTS, 'UNAVAILABLE_NO_RETAINED_INPUT', 'OUTSIDE_RETAINED_SUPPORT', 'FIT_UNAVAILABLE', 'NATIVE_TRANSFORM_UNAVAILABLE', ...LOESS_FIT_STATUSES.slice(1)] as readonly string[]
const supportStatuses = ['NO_RETAINED_INPUT', 'OUTSIDE_RETAINED_SUPPORT', 'WITHIN_RETAINED_RANGE', 'INSUFFICIENT_FITTING_SUPPORT'] as const
export type LoessSeries = SeriesFormat & {
  releaseId: string; outcome: LoessOutcome; spanPercent: number; scale: LoessScale
  sourceSha256: string; fitStatus: LoessFitStatus; unit: 'NATIVE' | 'SD'
  intervalStatus: 'NOT_EXPORTED_DESCRIPTIVE'
  columns: readonly ['TimeFromTransfusion', 'Estimate', 'PointStatus', 'SupportStatus']
  rows: readonly (readonly [number, number | null, string, string])[]
}
export interface LoessPoint { time: number; estimate: number | null; pointStatus: string; supportStatus: string }
function requireCondition(value: unknown, code: string): asserts value { if (!value) throw new Error(code) }
function object(value: unknown): Record<string, unknown> { requireCondition(value !== null && typeof value === 'object' && !Array.isArray(value), 'LOESS_OBJECT'); return value as Record<string, unknown> }
function exactKeys(value: Record<string, unknown>, keys: readonly string[]) { requireCondition(Object.keys(value).length === keys.length && keys.every(key => Object.prototype.hasOwnProperty.call(value, key)), 'LOESS_FIELDS') }
function digest(value: unknown): asserts value is string { requireCondition(typeof value === 'string' && /^[a-f0-9]{64}$/.test(value), 'LOESS_DIGEST') }
function parseReference(value: unknown, releaseId: string): ArtifactReference {
  const ref = object(value); exactKeys(ref, ['releaseId', 'url', 'sha256']); digest(ref.sha256)
  requireCondition(ref.releaseId === releaseId && typeof ref.url === 'string' && ref.url.startsWith(`data/releases/${releaseId}/`) && ref.url.endsWith('.json') && ref.url.split('/').every(segment => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment)), 'LOESS_REFERENCE')
  return Object.freeze({ releaseId, url: ref.url, sha256: ref.sha256 })
}
export function loessKey(entry: Pick<LoessEntry, 'outcome' | 'spanPercent' | 'scale'>): string { return `${entry.outcome}/${entry.spanPercent}/${entry.scale}` }
export function validateLoessManifest(value: unknown, release: ValidatedRelease, coreManifestSha256 = release.manifestSha256): ValidatedLoess {
  validateReleaseManifest(release.manifest, { mode: release.mode })
  digest(coreManifestSha256)
  const data = object(value)
  exactKeys(data, ['schemaVersion', 'releaseId', 'coreManifestSha256', 'datasetKind', 'diagnosticOnly', 'scientificApproved', 'publicationApproved', 'population', 'methodId', 'defaultSpanPercent', 'series'])
  requireCondition(data.schemaVersion === LOESS_SCHEMA && data.releaseId === release.manifest.releaseId && data.coreManifestSha256 === coreManifestSha256, 'LOESS_RELEASE_BINDING')
  for (const key of ['datasetKind', 'diagnosticOnly', 'scientificApproved', 'publicationApproved'] as const) requireCondition(data[key] === release.manifest[key], 'LOESS_RELEASE_POLICY')
  requireCondition(data.population === 'PRIMARY' && data.methodId === 'DIRECT_LINEAR_DISPLAY_V1' && data.defaultSpanPercent === 30, 'LOESS_METHOD')
  requireCondition(Array.isArray(data.series) && data.series.length === OUTCOMES.length * 81 * 2, 'LOESS_SERIES_UNIVERSE')
  const keys = new Set<string>(), paths = new Set<string>()
  const entries = data.series.map(raw => {
    const item = object(raw); exactKeys(item, ['outcome', 'spanPercent', 'scale', 'fitStatus', 'file'])
    requireCondition(OUTCOMES.includes(item.outcome as LoessOutcome) && Number.isInteger(item.spanPercent) && Number(item.spanPercent) >= 10 && Number(item.spanPercent) <= 90 && LOESS_SCALES.includes(item.scale as LoessScale) && LOESS_FIT_STATUSES.includes(item.fitStatus as LoessFitStatus), 'LOESS_SERIES_IDENTITY')
    const entry: LoessEntry = { outcome: item.outcome as LoessOutcome, spanPercent: item.spanPercent as number, scale: item.scale as LoessScale, fitStatus: item.fitStatus as LoessFitStatus, file: parseReference(item.file, release.manifest.releaseId) }
    const key = loessKey(entry)
    requireCondition(!keys.has(key) && !paths.has(entry.file.url), 'LOESS_DUPLICATE_SERIES'); keys.add(key); paths.add(entry.file.url)
    return Object.freeze(entry)
  })
  // All scale variants come from the same fitted descriptive curve.
  for (const entry of entries) requireCondition(entries.find(other => other.outcome === entry.outcome && other.spanPercent === entry.spanPercent && other.scale !== entry.scale)?.fitStatus === entry.fitStatus, 'LOESS_SCALE_FIT_MISMATCH')
  const manifest = Object.freeze({ ...data, series: Object.freeze(entries) }) as unknown as LoessManifest
  return Object.freeze({ manifest, release })
}
export function validateLoessSeries(value: unknown, supplement: ValidatedLoess, entry: LoessEntry, archived?: ArchivedCurveFormat): LoessSeries {
  const authoritative = supplement.manifest.series.find(item => loessKey(item) === loessKey(entry))
  requireCondition(authoritative && authoritative.file.sha256 === entry.file.sha256 && authoritative.file.url === entry.file.url && authoritative.fitStatus === entry.fitStatus, 'LOESS_SERIES_AUTHORITY')
  const data = object(value)
  exactKeys(data, ['schemaVersion', 'releaseId', 'outcome', 'spanPercent', 'scale', 'sourceSha256', 'fitStatus', 'unit', 'unitStatus', 'intervalStatus', 'methodAdoptionStatus', 'columns', 'rows'])
  const version = data.schemaVersion
  let methodStatus = 'DIRECT_DEGREE2_LOESS'
  let nativeUnitStatus = 'SOURCE_UNIT_UNCONFIRMED'
  if (version === FIRST_SERIES_SCHEMA) {
    // Check the archive format against the settings for the selected release.
    requireCondition(supplement.release.mode === 'analysis-tables' && archived &&
      archived.coreManifestSha256 === supplement.manifest.coreManifestSha256 &&
      typeof archived.methodAdoptionStatus === 'string' && archived.methodAdoptionStatus.length > 0 &&
      typeof archived.nativeUnitStatus === 'string' && archived.nativeUnitStatus.length > 0,
      'LOESS_ARCHIVED_FORMAT_REQUIRED')
    methodStatus = archived.methodAdoptionStatus
    nativeUnitStatus = archived.nativeUnitStatus
  } else requireCondition(version === LOESS_SERIES_SCHEMA, 'LOESS_SERIES_BINDING')
  requireCondition(data.releaseId === supplement.manifest.releaseId && data.outcome === entry.outcome && data.spanPercent === entry.spanPercent && data.scale === entry.scale && data.fitStatus === entry.fitStatus, 'LOESS_SERIES_BINDING')
  digest(data.sourceSha256)
  requireCondition(data.unit === (entry.scale === 'native' ? 'NATIVE' : 'SD') && data.unitStatus === (entry.scale === 'native' ? nativeUnitStatus : 'STANDARDIZED_GLOBAL_SD'), 'LOESS_UNITS')
  requireCondition(data.intervalStatus === 'NOT_EXPORTED_DESCRIPTIVE' && data.methodAdoptionStatus === methodStatus, 'LOESS_METHOD')
  requireCondition(JSON.stringify(data.columns) === JSON.stringify(['TimeFromTransfusion', 'Estimate', 'PointStatus', 'SupportStatus']), 'LOESS_COLUMNS')
  requireCondition(Array.isArray(data.rows) && data.rows.length === 1441, 'LOESS_GRID')
  const rows = data.rows.map((row: unknown, index: number) => {
    requireCondition(Array.isArray(row) && row.length === 4 && row[0] === index - 720 && (row[1] === null || typeof row[1] === 'number' && Number.isFinite(row[1])) && pointStatuses.includes(row[2] as string) && supportStatuses.includes(row[3] as typeof supportStatuses[number]), 'LOESS_GRID')
    const available = AVAILABLE_LOESS_POINTS.includes(row[2] as typeof AVAILABLE_LOESS_POINTS[number])
    requireCondition(available === (row[1] !== null), 'LOESS_POINT_AVAILABILITY')
    if (entry.fitStatus !== 'DIRECT_COMPLETED') requireCondition(row[2] === entry.fitStatus && row[3] === (entry.fitStatus === 'INSUFFICIENT_SUPPORT' ? 'INSUFFICIENT_FITTING_SUPPORT' : 'NO_RETAINED_INPUT'), 'LOESS_UNAVAILABLE_FIT')
    else {
      requireCondition(available || ['FIT_UNAVAILABLE', 'NATIVE_TRANSFORM_UNAVAILABLE', 'OUTSIDE_RETAINED_SUPPORT'].includes(row[2] as string), 'LOESS_POINT_STATUS')
      requireCondition(row[3] === (row[2] === 'OUTSIDE_RETAINED_SUPPORT' ? 'OUTSIDE_RETAINED_SUPPORT' : 'WITHIN_RETAINED_RANGE'), 'LOESS_SUPPORT')
      requireCondition(row[2] !== 'NATIVE_TRANSFORM_UNAVAILABLE' || entry.scale === 'native', 'LOESS_TRANSFORM_STATUS')
    }
    return Object.freeze([...row]) as readonly [number, number | null, string, string]
  })
  return Object.freeze({ ...data, columns: Object.freeze([...data.columns as string[]]), rows: Object.freeze(rows) }) as unknown as LoessSeries
}
export function loessPoints(series: LoessSeries): readonly LoessPoint[] { return series.rows.map(row => ({ time: row[0], estimate: row[1], pointStatus: row[2], supportStatus: row[3] })) }
/** Preserve absent predictions and support gaps; never connect across them. */
export function loessSegments(points: readonly LoessPoint[]): readonly (readonly LoessPoint[])[] {
  const segments: LoessPoint[][] = []; let part: LoessPoint[] = []
  for (const point of points) {
    if (point.estimate === null) { if (part.length) segments.push(part); part = []; continue }
    if (part.length && point.time !== part[part.length - 1]!.time + 1) { segments.push(part); part = [] }
    part.push(point)
  }
  if (part.length) segments.push(part)
  return segments
}
export function loessStatusLabel(status: string): string {
  const labels: Record<string, string> = { DIRECT_COMPLETED: 'Fitted curve available', FITTED: 'Fitted value', OUTSIDE_RETAINED_SUPPORT: 'Outside the fitted time range', FIT_UNAVAILABLE: 'Fitted value unavailable', NATIVE_TRANSFORM_UNAVAILABLE: 'Original-scale transformation unavailable', UNAVAILABLE_NO_INPUT: 'No eligible measurements', UNAVAILABLE_NO_RETAINED_INPUT: 'No retained measurements', UNAVAILABLE_ZERO_OR_UNDEFINED_SCALE: 'Standardization unavailable', INSUFFICIENT_SUPPORT: 'Insufficient fitting support', WITHIN_RETAINED_RANGE: 'Within the fitted time range', NO_RETAINED_INPUT: 'No retained measurements', INSUFFICIENT_FITTING_SUPPORT: 'Insufficient fitting support' }
  return labels[status] ?? 'Result unavailable'
}
