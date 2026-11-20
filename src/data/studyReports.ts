import type { FitKey } from './release'
import { FACTOR_LABELS, categoryLabel } from './display'
import { supplementRows, type ReportRole, type ReportTable } from './supplements'
import { numericCell, textCell, type TableRow } from './tables'
import { groupStudyUnits, minimizeStudyDisplay, type StudyDisplay, type StudyDisplayObject, type StudyRow } from './studyDisplay'

export const STUDY_REPORT_ROLES = ['rdd_cohort_counts', 'rdd_patient_age', 'rdd_patient_sex', 'rdd_patient_saps', 'rdd_unit_categories', 'rdd_units_per_person'] as const satisfies readonly ReportRole[]
export const COUNT_META = {
  PERSONS: { label: 'Patients', definition: 'ONE_PERSON_AT_FIRST_ELIGIBLE_EVENT' },
  ICU_ADMISSIONS: { label: 'ICU admissions', definition: 'CANONICAL_ADMISSIONS_IN_SUPPLIED_EVENTS' },
  INDEX_EVENTS: { label: 'Eligible transfusion events', definition: 'SUPPLIED_ELIGIBLE_INDEX_EVENTS' },
  LINKED_PHYSICAL_UNITS: { label: 'RBC units at these events', definition: 'PHYSICAL_UNITS_LINKED_TO_SUPPLIED_ELIGIBLE_INDEX_EVENTS' },
} as const
export const FACTOR_META = {
  DonorHb: { label: FACTOR_LABELS.DonorHb_Cat, codes: ['HB_1', 'HB_2', 'HB_3', 'HB_4', 'HB_5', 'HB_MISSING'] },
  Storage: { label: FACTOR_LABELS.Storage_Cat, codes: ['STORAGE_1', 'STORAGE_2', 'STORAGE_3', 'STORAGE_4', 'STORAGE_5', 'STORAGE_MISSING', 'STORAGE_INVALID'] },
  DonorSex: { label: 'Donor sex', codes: ['F', 'M', 'SEX_MISSING', 'SEX_INVALID'] },
  DonorParity: { label: 'Donor parity (female donors)', codes: ['PARITY_0', 'PARITY_1', 'PARITY_MISSING', 'PARITY_INVALID', 'EXCLUDED_MALE', 'EXCLUDED_MISSING_SEX', 'EXCLUDED_INVALID_SEX'] },
  DonationWeekday: { label: FACTOR_LABELS.wdy_donation, codes: ['DAY_2', 'DAY_3', 'DAY_4', 'DAY_5', 'DAY_6', 'DAY_7', 'DAY_1', 'WEEKDAY_MISSING', 'WEEKDAY_INVALID'] },
} as const
const SEX_LABELS = { F: 'Female', M: 'Male', MISSING: 'Missing', INVALID: 'Not coded female or male' } as const
const AGE_BANDS = { LT20: ['Younger than 20', 1], AGE20_29: ['20 to 29', 2], AGE30_39: ['30 to 39', 3], AGE40_49: ['40 to 49', 4], AGE50_59: ['50 to 59', 5], AGE60_69: ['60 to 69', 6], AGE70_79: ['70 to 79', 7], GE80: ['80 or older', 8], _MISSING_: ['Missing age', null] } as const
const CATEGORY_STATUS = { VALID: 'Available', MISSING: 'Missing', INVALID: 'Invalid recorded value', EXCLUDED: 'Excluded from denominator' } as const

export type CountUnit = keyof typeof COUNT_META
type UnitFactor = keyof typeof FACTOR_META
export type Numeric = number | null
interface DescriptiveSummary {
  mean: Numeric; sd: Numeric; median: Numeric; q1: Numeric; q3: Numeric
  available: Numeric; missing: Numeric; denominator: Numeric
}
interface UnitCategory { code: string; label: string; status: keyof typeof CATEGORY_STATUS; eligible: boolean; count: Numeric; percent: Numeric }
interface UnitGroup { factor: UnitFactor; total: Numeric; eligible: Numeric; valid: Numeric; missing: Numeric; invalid: Numeric; excluded: Numeric; rows: readonly UnitCategory[] }
export interface PopulationData {
  counts: Readonly<Record<CountUnit, Numeric>>
  age: DescriptiveSummary
  ageBands: readonly { code: string; label: string; count: Numeric; percent: Numeric }[] | null
  sex: readonly { code: keyof typeof SEX_LABELS; count: Numeric; percent: Numeric; denominator: Numeric }[]
  saps: DescriptiveSummary & { status: 'COMPUTED' | 'NOT_REQUESTED'; invalid: Numeric; notRequested: Numeric }
  units: readonly UnitGroup[]
  unitsPerPerson: readonly { units: Numeric; people: Numeric; denominator: Numeric; frequency: Numeric }[]
}
function check(value: unknown): asserts value { if (!value) throw new Error('POPULATION_REPORT_INVALID') }
function own(value: object, key: string): boolean { return Object.prototype.hasOwnProperty.call(value, key) }
function count(row: TableRow, field: string): Numeric {
  const value = numericCell(row, field)
  check(value === null || (Number.isInteger(value) && value >= 0))
  return value
}
function proportion(row: TableRow, field: string, maximum: number): Numeric {
  const value = numericCell(row, field)
  check(value === null || (value >= 0 && value <= maximum))
  return value
}
function denominator(row: TableRow): Numeric {
  check(textCell(row, 'DenominatorDefinition') === 'ONE_PERSON_AT_FIRST_ELIGIBLE_EVENT')
  check(textCell(row, 'DenominatorScope') === 'SUPPLIED_POPULATION_ELIGIBLE_PERSONS')
  return count(row, 'Denominator')
}
function single(table: ReportTable): TableRow {
  const rows = supplementRows(table)
  check(rows.length === 1)
  return rows[0]!
}
function knownEqual(a: Numeric, b: Numeric): void { if (a !== null && b !== null) check(a === b) }
function summary(row: TableRow, age: boolean): DescriptiveSummary {
  const result = {
    mean: numericCell(row, age ? 'Mean_Age' : 'Mean'), sd: numericCell(row, age ? 'SD_Age' : 'SD'),
    median: numericCell(row, age ? 'Median_Age' : 'Median'), q1: numericCell(row, age ? 'Q1_Age' : 'Q1'), q3: numericCell(row, age ? 'Q3_Age' : 'Q3'),
    available: count(row, age ? 'N_Age' : 'NAvailable'), missing: count(row, age ? 'N_Missing_Age' : 'NMissing'), denominator: denominator(row),
  }
  check(result.sd === null || result.sd >= 0)
  if (result.q1 !== null && result.median !== null) check(result.q1 <= result.median)
  if (result.q3 !== null && result.median !== null) check(result.median <= result.q3)
  knownEqual(count(row, 'NPersons'), result.denominator)
  return result
}
export function adapt(tables: readonly ReportTable[], ageGroups: ReportTable | null): PopulationData {
  const reports = Object.fromEntries(tables.map(table => [table.role, table])) as Record<typeof STUDY_REPORT_ROLES[number], ReportTable>
  check(tables.length === STUDY_REPORT_ROLES.length && new Set(tables.map(table => table.role)).size === STUDY_REPORT_ROLES.length && STUDY_REPORT_ROLES.every(role => own(reports, role)))
  const countRows = supplementRows(reports.rdd_cohort_counts)
  check(countRows.length === Object.keys(COUNT_META).length)
  const counts = {} as Record<CountUnit, Numeric>
  for (const row of countRows) {
    const unit = textCell(row, 'CountingUnit')
    check(own(COUNT_META, unit) && !own(counts, unit))
    const key = unit as CountUnit
    check(textCell(row, 'CountDefinition') === COUNT_META[key].definition)
    counts[key] = count(row, 'Count')
  }
  const age = summary(single(reports.rdd_patient_age), true)
  knownEqual(age.denominator, counts.PERSONS)
  const seenSex = new Set<string>()
  const sex = supplementRows(reports.rdd_patient_sex).map(row => {
    const code = textCell(row, 'Patient_Sex')
    check(own(SEX_LABELS, code) && !seenSex.has(code)); seenSex.add(code)
    const denominatorValue = denominator(row)
    knownEqual(denominatorValue, counts.PERSONS)
    return { code: code as keyof typeof SEX_LABELS, count: count(row, 'No_of_Patients'), percent: proportion(row, 'Percent', 100), denominator: denominatorValue }
  }).sort((a, b) => Object.keys(SEX_LABELS).indexOf(a.code) - Object.keys(SEX_LABELS).indexOf(b.code))
  const sapsRow = single(reports.rdd_patient_saps)
  const sapsStatus = textCell(sapsRow, 'Status')
  check(sapsStatus === 'COMPUTED' || sapsStatus === 'NOT_REQUESTED')
  const saps: PopulationData['saps'] = { ...summary(sapsRow, false), status: sapsStatus, invalid: count(sapsRow, 'NInvalid'), notRequested: count(sapsRow, 'NNotRequested') }
  knownEqual(saps.denominator, counts.PERSONS)
  const groups = new Map<UnitFactor, UnitGroup>()
  for (const row of supplementRows(reports.rdd_unit_categories)) {
    const factor = textCell(row, 'Factor'), code = textCell(row, 'CategoryCode'), status = textCell(row, 'Status')
    check(own(FACTOR_META, factor) && own(CATEGORY_STATUS, status))
    const key = factor as UnitFactor
    check((FACTOR_META[key].codes as readonly string[]).includes(code))
    const eligible = numericCell(row, 'Eligible')
    check(eligible === 0 || eligible === 1)
    check((eligible === 0) === (status === 'EXCLUDED'))
    check(eligible === 1 || key === 'DonorParity')
    check(textCell(row, 'DenominatorDefinition') === (key === 'DonorParity' ? 'FEMALE_DONOR_LINKED_INDEX_UNITS' : 'ALL_LINKED_INDEX_UNITS'))
    const context = {
      total: count(row, 'NTotalUnits'), eligible: count(row, 'NEligibleUnits'), valid: count(row, 'NValid'),
      missing: count(row, 'NMissing'), invalid: count(row, 'NInvalid'), excluded: count(row, 'NExcluded'),
    }
    knownEqual(context.total, counts.LINKED_PHYSICAL_UNITS)
    const existing = groups.get(key)
    if (existing) for (const field of ['total', 'eligible', 'valid', 'missing', 'invalid', 'excluded'] as const) check(existing[field] === context[field])
    const category: UnitCategory = { code, label: textCell(row, 'CategoryLabel'), status: status as keyof typeof CATEGORY_STATUS, eligible: eligible === 1, count: count(row, 'No_of_Transfused_Units'), percent: proportion(row, 'Percent', 100) }
    check(category.eligible || category.percent === null)
    check(!existing?.rows.some(value => value.code === code))
    groups.set(key, { factor: key, ...context, rows: [...(existing?.rows ?? []), category] })
  }
  const units = (Object.keys(FACTOR_META) as UnitFactor[]).filter(factor => groups.has(factor)).map(factor => {
    const group = groups.get(factor)!
    const order = FACTOR_META[factor].codes as readonly string[]
    return { ...group, rows: [...group.rows].sort((a, b) => order.indexOf(a.code) - order.indexOf(b.code)) }
  })
  const seenUnitCounts = new Set<string>()
  const unitsPerPerson = supplementRows(reports.rdd_units_per_person).map(row => {
    check(textCell(row, 'UnitScope') === 'ELIGIBLE_INDEX_EVENT_UNITS')
    check(textCell(row, 'CountDefinition') === 'PHYSICAL_UNITS_LINKED_TO_SUPPLIED_ELIGIBLE_INDEX_EVENTS')
    const unitsValue = count(row, 'Linked_Index_Units')
    const identity = String(unitsValue)
    check(!seenUnitCounts.has(identity)); seenUnitCounts.add(identity)
    const denominatorValue = denominator(row)
    knownEqual(denominatorValue, counts.PERSONS)
    return { units: unitsValue, people: count(row, 'No_of_Patients'), denominator: denominatorValue, frequency: proportion(row, 'Relative_Frequency', 1) }
  }).sort((a, b) => a.units === null ? 1 : b.units === null ? -1 : a.units - b.units)
  if (ageGroups !== null) check(ageGroups.role === 'rdd_patient_age_groups' && ageGroups.releaseId === tables[0]?.releaseId && ageGroups.reportKey.scope === 'population' && ageGroups.reportKey.population === tables[0]?.reportKey.population)
  const seenBands = new Set<string>()
  const ageBands = ageGroups === null ? null : supplementRows(ageGroups).map(row => {
    const band = textCell(row, 'BandCode')
    check(own(AGE_BANDS, band) && !seenBands.has(band)); seenBands.add(band)
    const [label, order] = AGE_BANDS[band as keyof typeof AGE_BANDS]
    check(numericCell(row, 'BandOrder') === order)
    knownEqual(denominator(row), counts.PERSONS)
    return { code: band, label, count: count(row, 'Count'), percent: proportion(row, 'Percent', 100) }
  }).sort((a, b) => Object.keys(AGE_BANDS).indexOf(a.code) - Object.keys(AGE_BANDS).indexOf(b.code))
  if (ageBands !== null && ageBands.length > 0 && ageBands.every(row => row.count !== null)) knownEqual(ageBands.reduce((total, row) => total + row.count!, 0), counts.PERSONS)
  return { counts, age, ageBands, sex, saps, units, unitsPerPerson }
}
function groupedUnits(rows: PopulationData['unitsPerPerson']): readonly { label: string; people: Numeric; percentage: Numeric }[] {
  const groups = [{ label: '0', min: 0, max: 0 }, { label: '1', min: 1, max: 1 }, { label: '2', min: 2, max: 2 }, { label: '3', min: 3, max: 3 }, { label: '4', min: 4, max: 4 }, { label: '5 to 9', min: 5, max: 9 }, { label: '10 or more', min: 10, max: Infinity }, { label: 'Number of units unavailable', min: null, max: null }]
  return groups.flatMap(group => {
    const members = rows.filter(row => group.min === null ? row.units === null : row.units !== null && row.units >= group.min && row.units <= group.max!)
    if (members.length === 0) return []
    const people = members.every(row => row.people !== null) ? members.reduce((sum, row) => sum + row.people!, 0) : null
    const denominatorValue = members[0]!.denominator
    const knownDenominator = denominatorValue !== null && denominatorValue > 0 && members.every(row => row.denominator === denominatorValue)
    return [{ label: group.label, people, percentage: people !== null && knownDenominator ? people / denominatorValue * 100 : null }]
  })
}
export function sapsHasNoMissing(table: ReportTable, releaseId: string, population: FitKey['population']): boolean {
  check(table.role === 'rdd_patient_saps' && table.releaseId === releaseId && table.reportKey.scope === 'population' && table.reportKey.population === population)
  const row = single(table)
  const result = summary(row, false)
  return textCell(row, 'Status') === 'COMPUTED' && result.missing === 0
}
function recipientSexLabel(code: keyof typeof SEX_LABELS, rows: PopulationData['sex']): string {
  if (code === 'INVALID') return 'Unknown (other recorded value)'
  if (code === 'MISSING') return rows.some(row => row.code === 'INVALID') ? 'Unknown (not recorded)' : 'Unknown'
  return SEX_LABELS[code]
}
function unitCategoryLabel(factor: UnitFactor, row: UnitCategory, rows: UnitGroup['rows']): string {
  if (row.status === 'MISSING') return rows.some(value => value.status === 'INVALID') ? 'Unknown (not recorded)' : 'Unknown'
  if (row.status === 'INVALID') return factor === 'Storage' ? 'Negative recorded storage duration' : 'Unknown (other recorded value)'
  if (row.code === 'EXCLUDED_MISSING_SEX') return 'Unknown donor sex'
  if (row.code === 'EXCLUDED_INVALID_SEX') return 'Other recorded donor sex'
  if (row.code === 'EXCLUDED_MALE') return 'Male donor' 
  if (factor === 'DonorHb' && /^HB_[1-5]$/.test(row.code)) return categoryLabel('DonorHb_Cat', row.code.slice(3))
  if (factor === 'Storage' && /^STORAGE_[1-5]$/.test(row.code)) return categoryLabel('Storage_Cat', row.code.slice(8))
  if (factor === 'DonorParity' && row.code === 'PARITY_0') return categoryLabel('DonorParity_Female', '0')
  if (factor === 'DonorParity' && row.code === 'PARITY_1') return categoryLabel('DonorParity_Female', '1')
  return row.label
}
function categoryCoverageNote(group: UnitGroup): string | null {
  const notes: string[] = []
  for (const [field, label] of [['eligible', 'Denominator'], ['total', 'Total linked units'], ['valid', 'Available-category count'], ['missing', 'Missing count'], ['invalid', 'Invalid-category count'], ['excluded', 'Excluded count']] as const) {
    if (group[field] === null) notes.push(`${label} unavailable.`)
  }
  for (const [field, status, label] of [['missing', 'MISSING', 'Missing'], ['invalid', 'INVALID', 'Invalid recorded category'], ['excluded', 'EXCLUDED', 'Excluded']] as const) {
    const reported = group.rows.filter(row => row.status === status)
    const total = group[field]
    if (total !== null && total > 0 && (reported.some(row => row.count === null) || reported.reduce((sum, row) => sum + (row.count ?? 0), 0) !== total)) notes.push(`${label}: ${value(total, 0)} units.`)
  }
  return notes.length ? notes.join(' ') : null
}
export function value(value: Numeric, digits = 1): string {
  return value === null ? 'Unavailable' : value.toLocaleString('en-GB', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}
function percentage(numerator: Numeric, denominator: Numeric): Numeric {
  return numerator === null || denominator === null || denominator <= 0 ? null : numerator / denominator * 100
}
export function showUnitCategory(factor: UnitFactor, row: UnitCategory): boolean {
  const unknown = row.status === 'MISSING' || (row.status === 'INVALID' && factor !== 'Storage') || row.code === 'EXCLUDED_MISSING_SEX' || row.code === 'EXCLUDED_INVALID_SEX'
  return (factor !== 'DonorParity' || row.eligible) && (!unknown || row.count !== 0)
}
export function projectStudy(data: PopulationData, complete: boolean | null): StudyDisplay {
  // Keep the original report percentages here, including any independently unavailable value.
  // The compact reader reconstructs the same visible cells from the displayed denominators.
  const rounded = (n: Numeric) => n === null ? null : Number(n.toLocaleString('en-GB', { useGrouping: false, minimumFractionDigits: 1, maximumFractionDigits: 1 }))
  const pair = (count: Numeric, percent: Numeric) => [count, rounded(percent)] as const
  const summaryMean = (s: DescriptiveSummary) => [rounded(s.mean), rounded(s.sd)] as const
  const summaryMedian = (s: DescriptiveSummary) => [rounded(s.median), rounded(s.q1), rounded(s.q3)] as const
  const visibleRow = (label: string, count: Numeric, percent: Numeric): StudyRow => [label, count, rounded(percent)]
  const requested = data.saps.status === 'COMPUTED'
  const hideMissing = requested && data.saps.missing === 0
  const scoreCount = (n: Numeric) => pair(n, percentage(n, data.saps.denominator))
  return {
    counts: data.counts,
    sex: data.sex.filter(row => (row.code !== 'MISSING' && row.code !== 'INVALID') || row.count !== 0)
      .map(row => visibleRow(recipientSexLabel(row.code, data.sex), row.count, row.percent)),
    age: { mean: summaryMean(data.age), median: summaryMedian(data.age), available: data.age.available, missing: data.age.missing },
    ageBands: data.ageBands?.length ? data.ageBands.filter(row => row.code !== '_MISSING_' || row.count !== 0)
      .map(row => visibleRow(row.code === '_MISSING_' ? 'Unknown' : row.label, row.count, row.percent)) : null,
    unitsPerPatient: groupedUnits(data.unitsPerPerson).map(row => visibleRow(row.label, row.people, row.percentage)),
    saps: {
      mean: requested ? summaryMean(data.saps) : null, median: requested ? summaryMedian(data.saps) : null,
      available: scoreCount(data.saps.available), missing: hideMissing ? null : scoreCount(data.saps.missing),
      invalid: scoreCount(data.saps.invalid), notRequested: requested && data.saps.notRequested === 0 ? [] : [data.saps.notRequested],
      allPopulationsComplete: complete === null ? null : complete && hideMissing,
    },
    units: groupStudyUnits(data.units.map(group => ({
      factor: group.factor, coverage: categoryCoverageNote(group),
      ...(group.factor === 'DonorParity' ? { parityDenominator: group.eligible } : {}),
      rows: group.rows.filter(row => showUnitCategory(group.factor, row))
        .map(row => visibleRow(unitCategoryLabel(group.factor, row, group.rows), row.count, row.percent)),
    })), data.counts.LINKED_PHYSICAL_UNITS),
  }
}

export function studyFromReports(tables: readonly ReportTable[], ageBands: ReportTable | null, allSapsComplete: boolean | null): StudyDisplayObject {
  const first = tables[0]
  check(first && first.reportKey.scope === 'population')
  const population = first.reportKey.population
  for (const table of ageBands ? [...tables, ageBands] : tables) {
    check(table.releaseId === first.releaseId && table.reportKey.scope === 'population' && table.reportKey.population === population)
  }
  return minimizeStudyDisplay('study/' + population, projectStudy(adapt(tables, ageBands), allSapsComplete))
}
