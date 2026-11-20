import type { CategoryComparison, ComponentComparison, PairComparison } from '../src/data/comparisons'
import { componentCategories, formatProbability, validateComponentDisplay, type ComponentFactor } from '../src/data/componentDisplay'

type Interval = [estimate:number, lower:number, upper:number]
type DisplayPair = [...Interval, raw:string, holm:number|string]

function interval(row:CategoryComparison | PairComparison): Interval {
  const {estimate, lower, upper} = row
  if (estimate === null || lower === null || upper === null ||
      ![estimate, lower, upper].every(Number.isFinite) || lower > estimate || estimate > upper) {
    throw new Error('Invalid component estimate or confidence interval')
  }
  return [estimate, lower, upper]
}

function probability(value:number): number {
  if (!Number.isFinite(value) || value < 0 || value > 1) throw new Error('Invalid component probability')
  return value
}

/** Project a comparison returned by readComparison to the fields used by the dashboard. */
export function projectComponent(key:string, comparison:ComponentComparison) {
  const factor = key.split('/')[3] as ComponentFactor
  const codes = componentCategories[factor]
  if (!Array.isArray(codes) || codes.length !== comparison.plannedCategoryCodes.length ||
      codes.length !== comparison.categories.length || codes.some((code,i) =>
        code !== comparison.plannedCategoryCodes[i] || code !== comparison.categories[i]?.code)) {
    throw new Error('Component categories do not match the selection')
  }
  const pairCount = codes.length * (codes.length - 1) / 2
  if (comparison.pairs.length + comparison.unavailablePairs.length !== pairCount) {
    throw new Error('Missing component comparison or extra pair')
  }
  if (comparison.tests.length !== 2 || !['endpoint','trajectory'].every(kind =>
    comparison.tests.some(test => test.kind === kind))) {
    throw new Error('Expected one endpoint and one trajectory test')
  }
  for (const pair of comparison.pairs) {
    probability(pair.pValue)
    probability(pair.holmP)
  }
  const ranked = [...comparison.pairs].sort((a,b) => a.pValue - b.pValue)
  let adjusted = 0
  for (const [i,pair] of ranked.entries()) {
    adjusted = Math.max(adjusted, Math.min(1, (ranked.length - i) * pair.pValue))
    if (!(Math.abs(adjusted - pair.holmP) <= 1e-12)) {
      throw new Error('Holm-adjusted probabilities do not match the reported family')
    }
  }
  const within = comparison.categories.map(row => row.status === 'UNAVAILABLE' ? null : interval(row))
  const pairs: (DisplayPair | null)[] = []
  for (const [index,a] of codes.entries()) {
    for (const b of codes.slice(index + 1)) {
      const pair = comparison.pairs.find(row => row.a === a && row.b === b)
      if (pair) {
        // The default-reference overview exposes the exact adjusted probability in its tooltip.
        const holm = index === 0 ? pair.holmP : formatProbability(pair.holmP)
        pairs.push([...interval(pair), formatProbability(pair.pValue), holm])
      } else {
        if (!comparison.unavailablePairs.some(row => row.a === a && row.b === b)) {
          throw new Error('Missing component comparison')
        }
        pairs.push(null)
      }
    }
  }
  const overall = Object.fromEntries(comparison.tests.map(test => [
    test.kind, [test.status, test.pValue === null ? null : formatProbability(probability(test.pValue))],
  ]))
  const display = {schema:'component-display-v1', key, within, pairs, overall}
  validateComponentDisplay(key, display)
  return display
}
