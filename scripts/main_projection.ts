import { validateMainDisplay } from '../src/data/mainDisplay'
import { numericCell, tableRows, textCell, trajectoryRows, type ResultTable } from '../src/data/tables'

type DisplayInterval = [number, number, number]

function interval(estimate: number | null, lower: number | null, upper: number | null): DisplayInterval {
  if (estimate === null || lower === null || upper === null ||
      ![estimate, lower, upper].every(value => Number.isFinite(value) && !Object.is(value, -0)) ||
      lower > estimate || estimate > upper) {
    throw new Error('MAIN_DISPLAY_INTERVAL')
  }
  return [estimate, lower, upper]
}

/** Project a verified MAIN table to the minute grid used by the reader and chart download. */
export function projectTrajectory(key: string, table: ResultTable): { key: string; points: DisplayInterval[] } {
  const { population, model, factor, outcome } = table.key
  const scale = table.role
  if (factor !== 'MAIN' || (scale !== 'levels' && scale !== 'changes') ||
      key !== ['main', population, model, outcome, scale].join('/')) {
    throw new Error('MAIN_DISPLAY_SELECTION')
  }
  const source = trajectoryRows(table)
  if (source.length !== 1441) throw new Error('MAIN_DISPLAY_MINUTE_GRID')
  const points = source.map((point, position) => {
    if (point.category !== 1 || point.time !== position - 720) throw new Error('MAIN_DISPLAY_MINUTE_GRID')
    const baseline = scale === 'changes' && point.time === -60
    if (point.numericStatus !== (baseline ? 'BASELINE_ZERO' : 'COMPUTED') ||
        point.contrastStatus !== (baseline ? 2 : 0)) {
      throw new Error('MAIN_DISPLAY_POINT_STATUS')
    }
    return interval(point.estimate, point.lower, point.upper)
  })
  const result = { key, points }
  validateMainDisplay(key, result)
  return result
}

/** Extract the independently estimated −60 to +60 minute change and its pointwise limits. */
export function projectEndpoint(table: ResultTable): DisplayInterval {
  if (table.key.factor !== 'MAIN' || table.role !== 'within' || table.rows.length !== 1) {
    throw new Error('MAIN_DISPLAY_ENDPOINT_SELECTION')
  }
  const row = tableRows(table)[0]!
  if (numericCell(row, 'BaselineMinute') !== -60 || numericCell(row, 'EndpointMinute') !== 60 ||
      textCell(row, 'NumericStatus') !== 'COMPUTED' || numericCell(row, 'ContrastStatus') !== 0) {
    throw new Error('MAIN_DISPLAY_ENDPOINT_STATUS')
  }
  return interval(numericCell(row, 'Estimate'), numericCell(row, 'Lower'), numericCell(row, 'Upper'))
}
