import { FACTORS, MODELS, OUTCOMES, POPULATIONS } from './release'
import figureStyle from './figureStyle.json'
import categoryLabels from './categoryLabels.json'

if (figureStyle.panels.length !== OUTCOMES.length || OUTCOMES.some(code => figureStyle.panels.filter(panel => panel.code === code).length !== 1)) throw new Error('FIGURE_PANEL_REGISTRY')

export const PANEL_ORDER = figureStyle.panels.map(panel => panel.code) as readonly (typeof OUTCOMES[number])[]

/** Clinical outcome names, display units and chart labels. */
export interface OutcomeMeta {
  readonly name: string
  readonly shortName: string
  readonly unit: string
  readonly changeUnit: string
  readonly color: string
  readonly unitNote?: string
}

const RECORDED_UNIT_NOTE =
  'Values remain on their recorded native scale; no unit conversion has been applied.'

export const OUTCOME_META = Object.fromEntries(figureStyle.panels.map(panel => [panel.code, {
  ...panel,
  unitNote: panel.code === 'FIO2'
    ? `${RECORDED_UNIT_NOTE} Whether this channel is measured or set has not been verified.`
    : panel.code === 'VE'
      ? `${RECORDED_UNIT_NOTE} Ventilation mode was not available for this analysis.`
      : RECORDED_UNIT_NOTE,
}])) as unknown as Readonly<Record<typeof OUTCOMES[number], OutcomeMeta>>


/** Two-line outcome headings shared by component overview and its figure export. */
export const OUTCOME_HEADING_LINES = {
  ARTm: ['Mean arterial', 'pressure'],
  ARTs: ['Systolic arterial', 'pressure'],
  ARTd: ['Diastolic arterial', 'pressure'],
  HR: ['Heart', 'rate'],
  FIO2: ['Fraction of', 'inspired oxygen'],
  SPO2: ['Peripheral oxygen', 'saturation'],
  VE: ['Minute', 'ventilation'],
} as const satisfies Readonly<Record<typeof OUTCOMES[number], readonly [string, string]>>

export const POPULATION_LABELS = {
  PRIMARY: 'Main analysis',
  FIRST_EVENT: 'First eligible event per person',
  NO_FOLLOWING_UNIT_12H: 'No further RBC unit within 12 hours',
} as const satisfies Readonly<Record<typeof POPULATIONS[number], string>>

export const POPULATION_NOTES = {
  PRIMARY: 'Eligible index events have no earlier recorded RBC transfusion, or the latest earlier transfusion was more than 12 hours before the index time.',
  FIRST_EVENT: 'The earliest eligible event per person is selected before outcome, factor and complete-case restrictions. This is not necessarily the first lifetime transfusion.',
  NO_FOLLOWING_UNIT_12H: 'No further recorded RBC unit starts after the index time through 12 hours later, inclusive. Complete declared transfusion-record coverage is required. Units sharing the index time belong to the index event.',
} as const satisfies Readonly<Record<typeof POPULATIONS[number], string>>

export const MODEL_LABELS = {
  BASE: 'Base model (comparison)',
  FULL: 'Full model (primary)',
} as const satisfies Readonly<Record<typeof MODELS[number], string>>

export const FACTOR_LABELS = {
  MAIN: 'All eligible events',
  DonorHb_Cat: 'Donor hemoglobin (g/L)',
  Storage_Cat: 'RBC storage duration (days)',
  DonorSex: 'Donor sex',
  DonorParity_Female: 'Donor parity (female donors only)',
  wdy_donation: 'Donation day',
} as const satisfies Readonly<Record<typeof FACTORS[number], string>>

/** Presentation order shared by component summaries and all-pairs figures. */
export const COMPONENT_FACTOR_ORDER = ['DonorHb_Cat', 'Storage_Cat', 'wdy_donation', 'DonorSex', 'DonorParity_Female'] as const satisfies readonly Exclude<typeof FACTORS[number], 'MAIN'>[]

/** Labels are keyed by the category codes in the analysis output. */
const CATEGORY_LABELS: Readonly<Record<typeof FACTORS[number], Readonly<Record<string, string>>>> = categoryLabels

export function categoryLabel(factor: typeof FACTORS[number], code: string | number): string {
  if (!Object.prototype.hasOwnProperty.call(CATEGORY_LABELS, factor)) throw new Error('UNKNOWN_FACTOR')
  const categories = CATEGORY_LABELS[factor]
  const key = String(code)
  if (!Object.prototype.hasOwnProperty.call(categories, key)) throw new Error('UNKNOWN_CATEGORY_CODE')
  return categories[key]!
}

export const PARITY_NOTE =
  'Among female donors, nulliparous means no previous births and parous means one or more previous births.'

export const CATEGORY_AVAILABILITY_LABELS = {
  AVAILABLE: 'Available',
  LOST_AT_COMPLETE_CASE: 'Absent after complete-case restriction',
  ABSENT_IN_SCOPE: 'Absent from the selected population',
} as const

export const JOB_STATE_LABELS = {
  accepted: 'Validated output',
  pending: 'Not yet available',
  failed: 'Analysis not accepted',
  inference_unavailable: 'Inference unavailable',
} as const

export const UNAVAILABLE_REASON_LABELS = {
  DECLARED_REFERENCE_LEVEL_ABSENT: 'The required reference category is absent.',
  EMPTY_MODEL_INPUT: 'No eligible measurements are available.',
  FACTOR_AVAILABLE_CATEGORIES_LT2: 'Fewer than two factor categories are available.',
  INSUFFICIENT_COMPLETE_ROWS: 'Too few measurements have complete information for this model.',
  INSUFFICIENT_PERSONS: 'Too few people contribute to this analysis.',
  NO_COMPLETE_MODEL_ROWS: 'No measurements have complete information for this model.',
  NO_OUTCOME_WINDOW_ROWS: 'No outcome measurements are available in the analysis window.',
  MOMENT_PRECISION_UNRESOLVED: 'An estimate is available, but its uncertainty could not be calculated reliably.',
} as const

export const TRAJECTORY_CAPTIONS = {
  levels: 'Lines show model-predicted means at the fit-specific reference profile. Bands show pointwise 95% confidence intervals for those means. Time is relative to the index transfusion start.',
  changes: 'Lines show change from the same model’s predicted value 60 minutes before transfusion. Bands show pointwise 95% confidence intervals for change, including covariance with that reference prediction. Time is relative to the index transfusion start.',
} as const

export const REFERENCE_PROFILE_NOTE =
  'Predictions represent a male recipient in the most commonly recorded ward, with the other adjustment variables set to their averages across the measurements included in that model. They are not averages of individual patients’ predictions.'

export const POINTWISE_INTERVAL_NOTE =
  'Confidence intervals account for repeated measurements within each patient using the CR2 cluster-robust method. They apply at each time point, rather than to the whole curve or an individual patient’s response.'

export const FULL_MODEL_NOTE =
  'The FULL model additionally adjusted for crystalloid, noradrenaline and sedative/analgesic treatment summaries from the 1 and 24 hours before each measurement. These summaries may include treatment after transfusion. BASE and FULL may include different measurements when adjustment data are missing. The patient characteristics used to calculate their curves can also differ. Differences between the models therefore cannot be attributed solely to treatment adjustment.'

export const PRIMARY_CHANGE_NOTE =
  'The primary comparison is the adjusted change from one hour before to one hour after transfusion. Its confidence interval accounts for the correlation between the two predictions.'

export const OBSERVED_COMPARISON_NOTE =
  'Observed comparisons average measurements within each event from −65 to −55 and +55 to +65 minutes, then compare the same paired events with equal event weighting and person-cluster inference. They are distinct from the model-based prediction contrast.'


// Donation-day comparisons require the separately validated Monday-to-Friday analysis.
export const DONATION_DAY_COMPARISON_CODES = ['2', '3', '4', '5', '6'] as const
export const DONATION_DAY_PENDING_NOTE = 'Monday-to-Friday comparisons are not yet available.'
