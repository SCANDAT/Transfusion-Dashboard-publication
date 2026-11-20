import { POPULATIONS } from './release'
import { categoryLabel } from './display'

export type StudyNumber = number | null
type CountAndPercent = readonly [StudyNumber, StudyNumber]
type SummaryPair = readonly [StudyNumber, StudyNumber]
type SummaryRange = readonly [StudyNumber, StudyNumber, StudyNumber]
export type StudyRow = readonly [string, StudyNumber, StudyNumber]
export type StudyFactor = 'DonorHb' | 'Storage' | 'DonorSex' | 'DonorParity' | 'DonationWeekday'
export type StudyCount = 'PERSONS' | 'ICU_ADMISSIONS' | 'INDEX_EVENTS' | 'LINKED_PHYSICAL_UNITS'
export interface StudyDisplay {
  counts: Record<StudyCount, StudyNumber>
  sex: readonly StudyRow[]
  age: { mean: SummaryPair; median: SummaryRange; available: StudyNumber; missing: StudyNumber }
  ageBands: readonly StudyRow[] | null
  unitsPerPatient: readonly StudyRow[]
  saps: {
    mean: SummaryPair | null; median: SummaryRange | null
    available: CountAndPercent; missing: CountAndPercent | null; invalid: CountAndPercent
    notRequested: readonly [] | readonly [StudyNumber]; allPopulationsComplete: boolean | null
  }
  units: readonly { factor: StudyFactor; rows: readonly StudyRow[]; coverage: string | null; parityDenominator?: StudyNumber }[]
}

type CountCell = StudyNumber | readonly [number, 'percent-unavailable']
type CountRow = readonly [string, CountCell]
export type StudyDisplayObject = Omit<StudyDisplay, 'sex' | 'ageBands' | 'unitsPerPatient' | 'saps' | 'units'> & {
  sex: readonly CountRow[]
  ageBands: readonly CountRow[] | null
  unitsPerPatient: readonly CountRow[]
  saps: Omit<StudyDisplay['saps'], 'available' | 'missing' | 'invalid'> & {
    available: CountCell; missing: readonly [] | readonly [CountCell]; invalid: CountCell
  }
  units: readonly (Omit<StudyDisplay['units'][number], 'rows'> & { rows: readonly CountRow[] })[]
}

const ageRows = [
  ['LT20', 'Younger than 20'], ['AGE20_29', '20 to 29'], ['AGE30_39','30 to 39'],
  ['AGE40_49','40 to 49'], ['AGE50_59','50 to 59'], ['AGE60_69','60 to 69'],
  ['AGE70_79','70 to 79'], ['GE80','80 or older'], ['_MISSING_', 'Unknown'],
]
function unknowns(missing: string, invalid?: string) {
  return [[missing,'Unknown'], [missing,'Unknown (not recorded)'], ...(invalid ? [[invalid, 'Unknown (other recorded value)']] : [])]
}
const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
const groupedSex = 'Male or unclassified donor sex'
const weekend = 'Weekend (Saturday and Sunday)'
const registry: Record<StudyFactor | 'sex' | 'ageBands' | 'unitsPerPatient', string[][]> = {
  ageBands: ageRows,
  unitsPerPatient: ['0','1','2','3','4','5 to 9','10 or more','Number of units unavailable'].map(label => [label,label]),
  sex: [['F','Female'], ['M','Male'], ...unknowns('MISSING','INVALID')],
  DonorHb: [...['1','2','3','4','5'].map(i=>['HB_'+i,categoryLabel('DonorHb_Cat',i)]), ...unknowns('HB_MISSING')],
  Storage: [...['1','2','3','4','5'].map(i=>['STORAGE_'+i,categoryLabel('Storage_Cat',i)]), ...unknowns('STORAGE_MISSING'), ['STORAGE_INVALID','Negative recorded storage duration']],
  DonorSex: [['F','Female'], ['OTHER_SEX_GROUP', groupedSex]],
  DonorParity: [['PARITY_0',categoryLabel('DonorParity_Female','0')], ['PARITY_1',categoryLabel('DonorParity_Female','1')], ...unknowns('PARITY_MISSING','PARITY_INVALID')],
  DonationWeekday: [...weekdays.map((label, index) => ['DAY_' + (index + 2), label]), ['WEEKEND', weekend]],
}
export function studyRowCode(group: keyof typeof registry, label: string): string {
  const row = registry[group].find(entry => entry[1] === label)
  requireStudy(row)
  return row[0]!
}
export function studyCategoryStatus(label: string): string {
  if (label === groupedSex || label === weekend) return 'GROUPED'
  if (label === 'Negative recorded storage duration' || label === 'Unknown (other recorded value)') return 'INVALID'
  return label.startsWith('Unknown') ? 'MISSING' : 'VALID'
}
function requireStudy(ok: unknown): asserts ok {
  if (!ok) throw new Error('Invalid study display data')
}
function fields(value: unknown, names: string[]): Record<string, unknown> {
  requireStudy(value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === names.length && names.every(key => Object.prototype.hasOwnProperty.call(value,key)))
  return value as Record<string, unknown>
}
function count(value: unknown): asserts value is StudyNumber {
  requireStudy(value === null || (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0))
}
function oneDecimal(value: unknown) {
  requireStudy(value === null || (typeof value === 'number' && Number.isFinite(value)
    && Number.isSafeInteger(Math.round(value * 10)) && Math.round(value * 10) / 10 === value))
}
function countAndPercent(value: unknown, denominator: StudyNumber): CountAndPercent {
  const unavailable = Array.isArray(value)
  if (Array.isArray(value)) {
    requireStudy(value.length === 2 && value[1] === 'percent-unavailable')
    value = value[0]
  }
  count(value)
  requireStudy(value === null || denominator === null || value <= denominator)
  if (value === null || denominator === null || denominator === 0) {
    requireStudy(!unavailable)
    return [value, null]
  }
  if (unavailable) return [value, null]
  const percent = (value / denominator * 100).toLocaleString('en-GB', {
    useGrouping: false, minimumFractionDigits: 1, maximumFractionDigits: 1,
  })
  return [value, Number(percent)]
}
type StudyUnits = StudyDisplay['units']

function unitRowTotal(input: readonly StudyRow[]): number {
  let total = 0
  for (const [, n] of input) {
    requireStudy(n !== null && Number.isSafeInteger(n) && n >= 0)
    total += n
    requireStudy(Number.isSafeInteger(total))
  }
  return total
}

function checkGroupedUnits(units: StudyUnits, total: StudyNumber) {
  const sex = units.find(group => group.factor === 'DonorSex')
  const day = units.find(group => group.factor === 'DonationWeekday')
  const parity = units.find(group => group.factor === 'DonorParity')
  requireStudy(sex && day && parity)
  for (const [group, expected] of [[sex, ['Female', groupedSex]], [day, [...weekdays, weekend]]] as const) {
    requireStudy(group.coverage === null && group.rows.length === expected.length)
    requireStudy(group.rows.every(([label], i) => label === expected[i]))
    requireStudy(unitRowTotal(group.rows) === total)
  }
  requireStudy(parity.coverage === null && parity.parityDenominator === sex.rows[0]![1])
  requireStudy(unitRowTotal(parity.rows) === parity.parityDenominator)
}

export function groupStudyUnits(units: StudyUnits, total: StudyNumber): StudyUnits {
  const projected = units.map(group => {
    if (group.factor !== 'DonorSex' && group.factor !== 'DonationWeekday') return group
    requireStudy(group.coverage === null && unitRowTotal(group.rows) === total)
    const byLabel = new Map(group.rows.map(row => [row[0], row]))
    requireStudy(byLabel.size === group.rows.length)
    const sex = group.factor === 'DonorSex'
    const separate = sex ? ['Female'] : weekdays
    const allowed = sex
      ? ['Female', 'Male', 'Unknown', 'Unknown (not recorded)', 'Unknown (other recorded value)']
      : [...weekdays, 'Saturday', 'Sunday']
    requireStudy(group.rows.every(([label]) => allowed.includes(label)))
    const required = sex ? ['Female', 'Male'] : weekdays
    requireStudy(required.every(label => byLabel.has(label)))
    const members = group.rows.filter(([label]) => !separate.includes(label))
    const n = unitRowTotal(members)
    const percent = countAndPercent(n, total)[1]
    const pooled: StudyRow = [sex ? groupedSex : weekend, n, percent]
    return { ...group, rows: [...separate.map(label => byLabel.get(label)!), pooled] }
  })
  checkGroupedUnits(projected, total)
  return projected
}

function statistics(mean: unknown, median: unknown, noObservations: boolean) {
  requireStudy(Array.isArray(mean) && mean.length === 2 && Array.isArray(median) && median.length === 3)
  for (const value of [...mean, ...median]) {
    oneDecimal(value)
    requireStudy(!noObservations || value === null)
  }
  requireStudy(mean[1] === null || mean[1] >= 0)
  requireStudy(median[1] === null || median[0] === null || median[1] <= median[0])
  requireStudy(median[2] === null || median[0] === null || median[0] <= median[2])
}
function rows(value: unknown, group: keyof typeof registry, denominator: StudyNumber): StudyRow[] {
  requireStudy(Array.isArray(value))
  const categories = [...new Set(registry[group].map(([code]) => code))]
  let previous = -1
  return value.map((row): StudyRow => {
    requireStudy(Array.isArray(row) && row.length === 2 && typeof row[0] === 'string')
    const index = categories.indexOf(studyRowCode(group, row[0]))
    requireStudy(index > previous)
    previous = index
    const [n, percent] = countAndPercent(row[1], denominator)
    requireStudy(!row[0].startsWith('Unknown') || n !== 0)
    return [row[0], n, percent]
  })
}
const missingNotes = ['Denominator', 'Total linked units', 'Available-category count', 'Missing count', 'Invalid-category count', 'Excluded count']
const totalNotes = ['Missing', 'Invalid recorded category', 'Excluded']
function coverage(value: unknown) {
  if (value === null) return
  requireStudy(typeof value === 'string' && value.length <= 360 && value.endsWith('.'))
  const parts = value.slice(0,-1).split('. ')
  let previous = -1
  for (const text of parts) {
    let index = missingNotes.findIndex(note => text === note + ' unavailable')
    if (index < 0) {
      const match = /^(Missing|Invalid recorded category|Excluded): ([1-9]\d{0,2}(?:,\d{3})*) units$/.exec(text)
      requireStudy(match && Number.isSafeInteger(Number(match[2]!.replace(/,/g,''))))
      index = missingNotes.length + totalNotes.indexOf(match[1]!)
    }
    requireStudy(index > previous)
    previous = index
  }
}
export function validateStudyDisplay(key: string, value: unknown): StudyDisplay {
  requireStudy(POPULATIONS.some(pop => key === 'study/' + pop))
  const data = fields(value, ['counts','sex','age','ageBands','unitsPerPatient','saps','units'])
  const counts = fields(data.counts, ['PERSONS','ICU_ADMISSIONS','INDEX_EVENTS','LINKED_PHYSICAL_UNITS'])
  Object.values(counts).forEach(count)
  const denominators = counts as StudyDisplay['counts']
  const people = denominators.PERSONS
  const sex = rows(data.sex, 'sex', people)
  const age = fields(data.age, ['mean','median','available','missing'])
  count(age.available); count(age.missing)
  if (people !== null) {
    requireStudy(age.available === null || age.available <= people)
    requireStudy(age.missing === null || age.missing <= people)
    requireStudy(age.available === null || age.missing === null || age.available === people - age.missing)
  }
  const noAges = age.available === 0 || people === 0 || (people !== null && age.missing === people)
  statistics(age.mean, age.median, noAges)
  const ageBands = data.ageBands === null ? null : rows(data.ageBands, 'ageBands', people)
  requireStudy(ageBands === null || ageBands.length > 0)
  const unitsPerPatient = rows(data.unitsPerPatient, 'unitsPerPatient', people)
  const saps = fields(data.saps, ['mean','median','available','missing','invalid','notRequested','allPopulationsComplete'])
  const available = countAndPercent(saps.available, people)
  if (saps.mean === null) requireStudy(saps.median === null)
  else statistics(saps.mean, saps.median, available[0] === 0 || people === 0)
  const invalid = countAndPercent(saps.invalid, people)
  requireStudy(Array.isArray(saps.missing) && saps.missing.length <= 1)
  const missing = saps.missing.length ? countAndPercent(saps.missing[0], people) : null
  requireStudy(missing === null || saps.mean === null || missing[0] !== 0)
  requireStudy(Array.isArray(saps.notRequested) && saps.notRequested.length <= 1)
  if (saps.notRequested.length) { count(saps.notRequested[0]); requireStudy(saps.mean === null || saps.notRequested[0] !== 0) }
  requireStudy(saps.mean !== null || (missing !== null && saps.notRequested.length === 1))
  requireStudy(saps.allPopulationsComplete === null || typeof saps.allPopulationsComplete === 'boolean')
  requireStudy(!saps.allPopulationsComplete || (saps.mean !== null && missing === null))
  requireStudy(Array.isArray(data.units))
  const factors: StudyFactor[] = ['DonorHb','Storage','DonorSex','DonorParity','DonationWeekday']
  let previous = -1
  const units = data.units.map((unit): StudyDisplay['units'][number] => {
    requireStudy(unit !== null && typeof unit === 'object' && typeof unit.factor === 'string' && factors.includes(unit.factor))
    const factor = unit.factor as StudyFactor
    const index = factors.indexOf(factor)
    requireStudy(index > previous); previous = index
    const group = fields(unit, factor === 'DonorParity' ? ['factor','rows','coverage','parityDenominator'] : ['factor','rows','coverage'])
    coverage(group.coverage)
    if (factor === 'DonorParity') count(group.parityDenominator)
    const denominator = factor === 'DonorParity' ? group.parityDenominator as StudyNumber : denominators.LINKED_PHYSICAL_UNITS
    return { factor, rows: rows(group.rows, factor, denominator), coverage: group.coverage as string | null,
      ...(factor === 'DonorParity' ? { parityDenominator: denominator } : {}) }
  })
  checkGroupedUnits(units, denominators.LINKED_PHYSICAL_UNITS)
  return {
    counts: denominators, sex, age: age as StudyDisplay['age'], ageBands, unitsPerPatient,
    saps: { mean: saps.mean as SummaryPair | null, median: saps.median as SummaryRange | null, available,
      missing, invalid, notRequested: saps.notRequested.length ? [saps.notRequested[0] as StudyNumber] : [], allPopulationsComplete: saps.allPopulationsComplete },
    units,
  }
}

export function minimizeStudyDisplay(key: string, presentation: StudyDisplay): StudyDisplayObject {
  const people = presentation.counts.PERSONS
  function cell(n: StudyNumber, percent: StudyNumber, denominator: StudyNumber): CountCell {
    const encoded: CountCell = n !== null && denominator !== null && denominator > 0 && percent === null
      ? [n, 'percent-unavailable'] : n
    // A reported percentage must match at the precision actually displayed.
    requireStudy(Object.is(countAndPercent(encoded, denominator)[1], percent))
    return encoded
  }
  const categories = (rows: readonly StudyRow[], denominator: StudyNumber): CountRow[] =>
    rows.map(([label, n, p]) => [label, cell(n, p, denominator)])
  const score = ([n, p]: CountAndPercent) => cell(n, p, people)
  const saps = presentation.saps
  const wire: StudyDisplayObject = {
    counts: presentation.counts, sex: categories(presentation.sex, people), age: presentation.age,
    ageBands: presentation.ageBands === null ? null : categories(presentation.ageBands, people),
    unitsPerPatient: categories(presentation.unitsPerPatient, people),
    saps: { ...saps, available: score(saps.available), missing: saps.missing === null ? [] : [score(saps.missing)], invalid: score(saps.invalid) },
    units: presentation.units.map(group => ({
      factor: group.factor,
      rows: categories(group.rows, group.factor === 'DonorParity'
        ? group.parityDenominator ?? null : presentation.counts.LINKED_PHYSICAL_UNITS),
      coverage: group.coverage,
      ...(group.factor === 'DonorParity' ? { parityDenominator: group.parityDenominator } : {}),
    })),
  }
  validateStudyDisplay(key, wire)
  return wire
}
