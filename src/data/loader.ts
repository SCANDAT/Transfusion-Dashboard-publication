import {
  artifactCacheKey, getAuthoritativeReference, validateReleaseManifest,
  type AuthoritativeRole, type FitKey, type ReleaseMode, type ValidatedRelease,
} from './release'
import { validateResultTable, type ResultTable } from './tables'
import {
  validateSupplementManifest, validateReportTable, validateProfileTable, validateMethods,
  type ValidatedSupplement, type ReportKey, type ReportRole,
} from './supplements'
import type { ArtifactReference } from './release'

export type LoaderErrorCode =
  | 'INVALID_BASE_URL' | 'UNSCOPED_URL' | 'HTTP_ERROR' | 'REDIRECT_REJECTED'
  | 'ASSET_HASH_MISMATCH' | 'INVALID_JSON' | 'CRYPTO_UNAVAILABLE'
  | 'CORE_MANIFEST_DIGEST_REQUIRED' | 'SUPPLEMENT_ROLE_UNAVAILABLE'

export class ResultLoadError extends Error {
  constructor(readonly code: LoaderErrorCode) {
    super(code)
    this.name = 'ResultLoadError'
  }
}

function check(value: unknown, code: LoaderErrorCode): asserts value {
  if (!value) throw new ResultLoadError(code)
}

function aborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new DOMException('Request aborted', 'AbortError')
}

/** Resolve a root-relative asset directory on the current origin. */
function scopedUrl(baseUrl: string, relative: string): string {
  check(typeof baseUrl === 'string' && baseUrl.startsWith('/') && !baseUrl.startsWith('//')
    && baseUrl.endsWith('/') && !/[\\%?#:\s]/.test(baseUrl), 'INVALID_BASE_URL')
  const baseSegments = baseUrl.slice(1, -1).split('/').filter(segment => segment.length > 0)
  check(!baseUrl.includes('//') && baseSegments.every(segment => segment !== '.' && segment !== '..'
    && /^[A-Za-z0-9._-]+$/.test(segment)), 'INVALID_BASE_URL')
  check(relative.length > 0 && relative.split('/').every(segment =>
    /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment)), 'UNSCOPED_URL')
  const origin = globalThis.location.origin
  check(/^https?:\/\//.test(origin), 'INVALID_BASE_URL')
  const base = new URL(baseUrl, origin)
  const url = new URL(relative, base)
  check(url.origin === origin && url.pathname.startsWith(base.pathname), 'UNSCOPED_URL')
  return url.href
}

async function bytes(url: string, signal?: AbortSignal, options?: { optional?: false; cache?: RequestCache }): Promise<ArrayBuffer>
async function bytes(url: string, signal: AbortSignal | undefined, options: { optional: true; cache?: RequestCache }): Promise<ArrayBuffer | null>
async function bytes(url: string, signal?: AbortSignal, options: { optional?: boolean; cache?: RequestCache } = {}): Promise<ArrayBuffer | null> {
  aborted(signal)
  const response = await fetch(url, { signal, cache: options.cache ?? 'no-store', redirect: 'error', credentials: 'same-origin' })
  aborted(signal)
  check(!response.redirected && response.url === url, 'REDIRECT_REJECTED')
  if (options.optional && response.status === 404) return null
  check(response.ok, 'HTTP_ERROR')
  const data = await response.arrayBuffer()
  aborted(signal)
  return data
}

function parseJson(data: ArrayBuffer): unknown {
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(data)) as unknown
  } catch {
    throw new ResultLoadError('INVALID_JSON')
  }
}

async function sha256(data: ArrayBuffer): Promise<string> {
  check(globalThis.crypto?.subtle !== undefined, 'CRYPTO_UNAVAILABLE')
  const digest = await globalThis.crypto.subtle.digest('SHA-256', data)
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
}

/** Read the current release manifest on each request. */
export async function loadRelease(
  baseUrl: string, mode: ReleaseMode, signal?: AbortSignal,
): Promise<ValidatedRelease> {
  const data = await bytes(scopedUrl(baseUrl, 'release.json'), signal)
  aborted(signal)
  const release = validateReleaseManifest(parseJson(data), { mode })
  const manifestSha256 = await sha256(data)
  aborted(signal)
  return Object.freeze({ ...release, manifestSha256 })
}

// Cache verified tables after loading. Each caller has a separate request
// so cancelling one selection leaves other requests active.
const MAX_CACHED_TABLES = 12
const completed = new Map<string, ResultTable>()

export function clearResultCache(): void {
  completed.clear()
}

export async function loadTable(
  release: ValidatedRelease, key: FitKey, role: AuthoritativeRole,
  baseUrl: string, signal?: AbortSignal,
): Promise<ResultTable> {
  aborted(signal)
  // Check release eligibility before fetching a table.
  const checkedRelease = validateReleaseManifest(release.manifest, { mode: release.mode })
  const ref = getAuthoritativeReference(checkedRelease, key, role)
  const url = scopedUrl(baseUrl, ref.url)
  const cacheKey = JSON.stringify([url, checkedRelease.mode, artifactCacheKey(checkedRelease, key, role)])
  const cached = completed.get(cacheKey)
  if (cached !== undefined) {
    aborted(signal)
    completed.delete(cacheKey)
    completed.set(cacheKey, cached)
    return cached
  }
  const data = await bytes(url, signal, { cache: 'force-cache' })
  const digest = await sha256(data)
  aborted(signal)
  check(digest === ref.sha256, 'ASSET_HASH_MISMATCH')
  const table = validateResultTable(parseJson(data), checkedRelease, key, role)
  aborted(signal)
  completed.set(cacheKey, table)
  if (completed.size > MAX_CACHED_TABLES) {
    const oldest = completed.keys().next().value as string | undefined
    if (oldest !== undefined) completed.delete(oldest)
  }
  return table
}


function coreDigest(release: ValidatedRelease): string {
  check(typeof release.manifestSha256 === 'string' && /^[a-f0-9]{64}$/.test(release.manifestSha256), 'CORE_MANIFEST_DIGEST_REQUIRED')
  return release.manifestSha256
}
function checkedSupplement(supplement: ValidatedSupplement): ValidatedSupplement {
  return validateSupplementManifest(supplement.manifest, supplement.release, coreDigest(supplement.release))
}
async function supplementalPayload(reference: ArtifactReference, baseUrl: string, signal?: AbortSignal): Promise<unknown> {
  const data = await bytes(scopedUrl(baseUrl, reference.url), signal, { cache: 'force-cache' })
  const digest = await sha256(data)
  aborted(signal)
  check(digest === reference.sha256, 'ASSET_HASH_MISMATCH')
  return parseJson(data)
}

/** Absence is distinct from an invalid, mismatched or unapproved supplement. */
export async function loadSupplements(release: ValidatedRelease, baseUrl: string, signal?: AbortSignal): Promise<ValidatedSupplement | null> {
  aborted(signal)
  const digest = coreDigest(release)
  const data = await bytes(scopedUrl(baseUrl, 'supplements.json'), signal, { optional: true })
  aborted(signal)
  return data === null ? null : validateSupplementManifest(parseJson(data), release, digest)
}
export async function loadReport(supplement: ValidatedSupplement, key: ReportKey, role: ReportRole, baseUrl: string, signal?: AbortSignal): Promise<ReturnType<typeof validateReportTable>> {
  aborted(signal)
  const checked = checkedSupplement(supplement)
  const report = checked.manifest.reports.find(item => item.key.scope === key.scope && item.key.population === key.population)
  const reference = report?.state === 'accepted' ? report.files[role] : undefined
  check(reference !== undefined, 'SUPPLEMENT_ROLE_UNAVAILABLE')
  const value = await supplementalPayload(reference, baseUrl, signal)
  aborted(signal)
  return validateReportTable(value, checked, key, role)
}
export async function loadProfile(supplement: ValidatedSupplement, key: FitKey, modelTable: ResultTable, baseUrl: string, signal?: AbortSignal): Promise<ReturnType<typeof validateProfileTable>> {
  aborted(signal)
  const checked = checkedSupplement(supplement)
  const profile = checked.manifest.profiles.find(item => item.key.population === key.population && item.key.model === key.model && item.key.factor === key.factor && item.key.outcome === key.outcome)
  check(profile?.state === 'available', 'SUPPLEMENT_ROLE_UNAVAILABLE')
  const value = await supplementalPayload(profile.file, baseUrl, signal)
  aborted(signal)
  return validateProfileTable(value, checked, key, modelTable)
}
export async function loadMethods(supplement: ValidatedSupplement, baseUrl: string, signal?: AbortSignal): Promise<ReturnType<typeof validateMethods>> {
  aborted(signal)
  const checked = checkedSupplement(supplement)
  const value = await supplementalPayload(checked.manifest.methods, baseUrl, signal)
  aborted(signal)
  return validateMethods(value, checked)
}
