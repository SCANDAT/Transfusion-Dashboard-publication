/** Validate the planned fits, result references and publication flags in the dashboard manifest. */
export const RELEASE_SCHEMA = 'transfusion-dashboard/release-v1' as const

export const POPULATIONS = ['PRIMARY', 'FIRST_EVENT', 'NO_FOLLOWING_UNIT_12H'] as const
export const MODELS = ['BASE', 'FULL'] as const
export const FACTORS = ['MAIN', 'DonorHb_Cat', 'Storage_Cat', 'DonorSex', 'DonorParity_Female', 'wdy_donation'] as const
export const OUTCOMES = ['ARTm', 'ARTs', 'ARTd', 'HR', 'FIO2', 'SPO2', 'VE'] as const
export const AUTHORITATIVE_ROLES = ['levels', 'changes', 'within', 'pairwise', 'joint'] as const

export type DatasetKind = 'full_cohort' | 'development_sample'
export type AuthoritativeRole = typeof AUTHORITATIVE_ROLES[number]
export type ReleaseMode = 'production' | 'analysis-tables'

export interface FitKey {
  readonly population: typeof POPULATIONS[number]
  readonly model: typeof MODELS[number]
  readonly factor: typeof FACTORS[number]
  readonly outcome: typeof OUTCOMES[number]
}

export interface FitPlan {
  /** Planned category codes, including categories absent from available results. */
  readonly categoryCodes: readonly string[]
  readonly requestedRoles: readonly AuthoritativeRole[]
}

export interface ArtifactReference {
  readonly releaseId: string
  /** Canonical relative path below data/releases/<releaseId>/. */
  readonly url: string
  readonly sha256: string
}

interface PlannedJob {
  readonly key: FitKey
  readonly plan: FitPlan
}

export interface AcceptedJob extends PlannedJob {
  readonly state: 'accepted'
  readonly authority: 'validated_inference'
  readonly files: Readonly<Partial<Record<AuthoritativeRole, ArtifactReference>>>
}

export interface UnavailableJob extends PlannedJob {
  readonly state: 'pending' | 'failed' | 'inference_unavailable'
  readonly reasonCode: string
  /** These states have no numerical assets; metadata and plans remain above. */
}

export type ReleaseJob = AcceptedJob | UnavailableJob

export interface ReleaseManifest {
  readonly schemaVersion: typeof RELEASE_SCHEMA
  /** Immutable selection snapshot. A changed selection needs a new releaseId. */
  readonly releaseId: string
  readonly datasetKind: DatasetKind
  readonly diagnosticOnly: boolean
  readonly scientificApproved: boolean
  readonly publicationApproved: boolean
  /** One record for every planned fit. */
  readonly jobs: readonly ReleaseJob[]
}

export interface ValidatedRelease {
  /** SHA256 of the exact fetched manifest bytes; absent for validation of an in-memory object. */
  readonly manifestSha256?: string
  readonly manifest: ReleaseManifest
  readonly mode: ReleaseMode
  /** Whether the release is eligible for publication. */
  readonly publicationEligible: boolean
  readonly plannedUniverseComplete: boolean
}

export type ReleaseErrorCode =
  | 'INVALID_STRUCTURE' | 'UNEXPECTED_FIELD' | 'UNSUPPORTED_SCHEMA'
  | 'INVALID_ENUM' | 'INVALID_IDENTIFIER' | 'INVALID_BOOLEAN' | 'INVALID_HASH'
  | 'INVALID_RELATIVE_URL' | 'RELEASE_MISMATCH' | 'DUPLICATE_FIT_KEY'
  | 'DUPLICATE_ASSET_PATH' | 'INVALID_PLAN' | 'INVALID_AUTHORITY'
  | 'ASSET_PLAN_MISMATCH' | 'PRODUCTION_RELEASE_REQUIRED'
  | 'PUBLICATION_APPROVAL_REQUIRED' | 'SCIENTIFIC_APPROVAL_REQUIRED'
  | 'PRODUCTION_PENDING_JOB' | 'PRODUCTION_FAILED_JOB' | 'PRODUCTION_PLAN_INCOMPLETE'
  | 'JOB_NOT_FOUND' | 'JOB_NOT_ACCEPTED'
  | 'ROLE_NOT_AVAILABLE'

export class ReleaseValidationError extends Error {
  constructor(readonly code: ReleaseErrorCode) {
    super(code)
    this.name = 'ReleaseValidationError'
  }
}

function check(value: unknown, code: ReleaseErrorCode): asserts value {
  if (!value) throw new ReleaseValidationError(code)
}

function record(value: unknown, keys: readonly string[]): Record<string, unknown> {
  check(typeof value === 'object' && value !== null && !Array.isArray(value), 'INVALID_STRUCTURE')
  const object = value as Record<string, unknown>
  check(Object.keys(object).length === keys.length && keys.every(key =>
    Object.prototype.hasOwnProperty.call(object, key)), 'UNEXPECTED_FIELD')
  check(Object.keys(object).every(key => keys.includes(key)), 'UNEXPECTED_FIELD')
  return object
}

function oneOf<const T extends readonly string[]>(value: unknown, values: T): T[number] {
  check(typeof value === 'string' && values.includes(value), 'INVALID_ENUM')
  return value as T[number]
}

function bool(value: unknown): boolean {
  check(typeof value === 'boolean', 'INVALID_BOOLEAN')
  return value
}

function identifier(value: unknown): string {
  check(typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(value), 'INVALID_IDENTIFIER')
  return value
}

function parseFitKey(value: unknown): FitKey {
  const key = record(value, ['population', 'model', 'factor', 'outcome'])
  return Object.freeze({
    population: oneOf(key.population, POPULATIONS),
    model: oneOf(key.model, MODELS),
    factor: oneOf(key.factor, FACTORS),
    outcome: oneOf(key.outcome, OUTCOMES),
  })
}

function selectionKey(key: FitKey): string {
  return JSON.stringify([key.population, key.model, key.factor, key.outcome])
}

function parsePlan(value: unknown, key: FitKey): FitPlan {
  const plan = record(value, ['categoryCodes', 'requestedRoles'])
  check(Array.isArray(plan.categoryCodes) && plan.categoryCodes.length > 0, 'INVALID_PLAN')
  const categoryCodes = plan.categoryCodes.map(identifier)
  check(new Set(categoryCodes).size === categoryCodes.length, 'INVALID_PLAN')
  if (key.factor === 'MAIN') check(categoryCodes.length === 1, 'INVALID_PLAN')
  check(Array.isArray(plan.requestedRoles), 'INVALID_PLAN')
  const requestedRoles = plan.requestedRoles.map(role => oneOf(role, AUTHORITATIVE_ROLES))
  check(new Set(requestedRoles).size === requestedRoles.length, 'INVALID_PLAN')
  const required: readonly AuthoritativeRole[] = key.factor === 'MAIN'
    ? ['levels', 'changes', 'within']
    : AUTHORITATIVE_ROLES
  check(required.every(role => requestedRoles.includes(role)), 'INVALID_PLAN')
  return Object.freeze({
    categoryCodes: Object.freeze(categoryCodes),
    requestedRoles: Object.freeze(requestedRoles),
  })
}

function parseReference(value: unknown, releaseId: string): ArtifactReference {
  const ref = record(value, ['releaseId', 'url', 'sha256'])
  check(identifier(ref.releaseId) === releaseId, 'RELEASE_MISMATCH')
  check(typeof ref.url === 'string', 'INVALID_RELATIVE_URL')
  // No absolute/network paths, escaped separators, traversal, query or fragment.
  const segments = ref.url.split('/')
  check(segments.every(segment => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment)), 'INVALID_RELATIVE_URL')
  check(ref.url.startsWith('data/releases/' + releaseId + '/'), 'RELEASE_MISMATCH')
  check(/\.(csv|json)$/.test(ref.url), 'INVALID_RELATIVE_URL')
  check(typeof ref.sha256 === 'string' && /^[a-f0-9]{64}$/.test(ref.sha256), 'INVALID_HASH')
  return Object.freeze({ releaseId, url: ref.url, sha256: ref.sha256 })
}

export function validateReleaseManifest(
  value: unknown,
  options: { readonly mode: ReleaseMode; readonly expectedReleaseId?: string },
): ValidatedRelease {
  const mode = oneOf(options.mode, ['production', 'analysis-tables'] as const)
  const input = record(value, [
    'schemaVersion', 'releaseId', 'datasetKind', 'diagnosticOnly',
    'scientificApproved', 'publicationApproved', 'jobs',
  ])
  check(input.schemaVersion === RELEASE_SCHEMA, 'UNSUPPORTED_SCHEMA')
  const releaseId = identifier(input.releaseId)
  if (options.expectedReleaseId !== undefined) {
    check(releaseId === identifier(options.expectedReleaseId), 'RELEASE_MISMATCH')
  }
  const datasetKind = oneOf(input.datasetKind, ['full_cohort', 'development_sample'] as const)
  const diagnosticOnly = bool(input.diagnosticOnly)
  const scientificApproved = bool(input.scientificApproved)
  const publicationApproved = bool(input.publicationApproved)
  check(Array.isArray(input.jobs) && input.jobs.length > 0, 'INVALID_PLAN')
  const fitKeys = new Set<string>()
  const paths = new Set<string>()
  const jobs: ReleaseJob[] = input.jobs.map(value => {
    check(typeof value === 'object' && value !== null && !Array.isArray(value), 'INVALID_STRUCTURE')
    const state = oneOf((value as Record<string, unknown>).state,
      ['accepted', 'pending', 'failed', 'inference_unavailable'] as const)
    const job = record(value, state === 'accepted'
      ? ['key', 'plan', 'state', 'authority', 'files']
      : ['key', 'plan', 'state', 'reasonCode'])
    const key = parseFitKey(job.key)
    const fit = selectionKey(key)
    check(!fitKeys.has(fit), 'DUPLICATE_FIT_KEY')
    fitKeys.add(fit)
    const plan = parsePlan(job.plan, key)
    if (state !== 'accepted') {
      check(typeof job.reasonCode === 'string' && /^[A-Z][A-Z0-9_]{0,95}$/.test(job.reasonCode), 'INVALID_IDENTIFIER')
      return Object.freeze({ key, plan, state, reasonCode: job.reasonCode })
    }
    check(job.authority === 'validated_inference', 'INVALID_AUTHORITY')
    const inputFiles = record(job.files, plan.requestedRoles)
    const files: Partial<Record<AuthoritativeRole, ArtifactReference>> = {}
    for (const role of plan.requestedRoles) {
      const ref = parseReference(inputFiles[role], releaseId)
      check(!paths.has(ref.url), 'DUPLICATE_ASSET_PATH')
      paths.add(ref.url)
      files[role] = ref
    }
    check(Object.keys(files).length === plan.requestedRoles.length, 'ASSET_PLAN_MISMATCH')
    return Object.freeze({ key, plan, state, authority: 'validated_inference', files: Object.freeze(files) })
  })
  const hasPending = jobs.some(job => job.state === 'pending')
  const hasFailed = jobs.some(job => job.state === 'failed')
  // Unique keys and the expected count cover every combination of fit dimensions.
  const expectedFitCount = POPULATIONS.length * MODELS.length * FACTORS.length * OUTCOMES.length
  const plannedUniverseComplete = jobs.length === expectedFitCount
  const publicationEligible = datasetKind === 'full_cohort' && !diagnosticOnly
    && scientificApproved && publicationApproved && !hasPending && !hasFailed && plannedUniverseComplete
  if (mode === 'production') {
    check(datasetKind === 'full_cohort' && !diagnosticOnly, 'PRODUCTION_RELEASE_REQUIRED')
    check(scientificApproved, 'SCIENTIFIC_APPROVAL_REQUIRED')
    check(publicationApproved, 'PUBLICATION_APPROVAL_REQUIRED')
    check(plannedUniverseComplete, 'PRODUCTION_PLAN_INCOMPLETE')
    check(!hasPending, 'PRODUCTION_PENDING_JOB')
    check(!hasFailed, 'PRODUCTION_FAILED_JOB')
  }
  const manifest: ReleaseManifest = Object.freeze({
    schemaVersion: RELEASE_SCHEMA, releaseId, datasetKind, diagnosticOnly,
    scientificApproved, publicationApproved, jobs: Object.freeze(jobs),
  })
  return Object.freeze({ manifest, mode, publicationEligible, plannedUniverseComplete })
}

/** Distinguishes release, cohort, sensitivity, adjustment, factor and outcome. */
export function fitCacheKey(release: ValidatedRelease, key: FitKey): string {
  const checked = parseFitKey(key)
  return JSON.stringify([
    RELEASE_SCHEMA, release.manifest.releaseId, release.manifest.datasetKind,
    checked.population, checked.model, checked.factor, checked.outcome,
  ])
}

/** Select the requested role from an accepted fit. */
export function getAuthoritativeReference(
  release: ValidatedRelease, key: FitKey, role: AuthoritativeRole,
): ArtifactReference {
  const checked = parseFitKey(key)
  const checkedRole = oneOf(role, AUTHORITATIVE_ROLES)
  const job = release.manifest.jobs.find(candidate => selectionKey(candidate.key) === selectionKey(checked))
  check(job !== undefined, 'JOB_NOT_FOUND')
  check(job.state === 'accepted', 'JOB_NOT_ACCEPTED')
  const reference = job.files[checkedRole]
  check(reference !== undefined, 'ROLE_NOT_AVAILABLE')
  return reference
}

/** Includes role and exact asset digest, which also binds its scored profile. */
export function artifactCacheKey(
  release: ValidatedRelease, key: FitKey, role: AuthoritativeRole,
): string {
  const reference = getAuthoritativeReference(release, key, role)
  return JSON.stringify([fitCacheKey(release, key), role, reference.sha256])
}


