import type { DisplayComparison, DisplayProbability } from './componentDisplay'
import type { ComponentComparison } from './comparisons'

export interface DisplayPair {
  id: string; a: string; b: string
  estimate: number | null; lower: number | null; upper: number | null
  pValue: DisplayProbability | null; holmP: DisplayProbability | null; status: 'COMPUTED' | 'UNAVAILABLE'
}

/** Reverse the reported contrast and bounds when the reference category changes. */
export function displayPairs(result: Pick<DisplayComparison | ComponentComparison, 'plannedCategoryCodes' | 'pairs' | 'unavailablePairs'>, reference: string | null): DisplayPair[] {
  const codes = result.plannedCategoryCodes
  if (reference !== null && !codes.includes(reference)) throw new Error('UNKNOWN_DISPLAY_REFERENCE')
  const stored: DisplayPair[] = [...result.pairs.map(pair => ({ ...pair, id: `${pair.a}/${pair.b}` })),
    ...result.unavailablePairs.map(pair => ({ ...pair, id: `${pair.a}/${pair.b}`, estimate: null, lower: null, upper: null, pValue: null, holmP: null }))]
  if (reference === null) return stored.sort((a, b) => codes.indexOf(a.a) - codes.indexOf(b.a) || codes.indexOf(a.b) - codes.indexOf(b.b))
  return codes.filter(code => code !== reference).map(code => {
    const pair = stored.find(item => item.a === code && item.b === reference || item.a === reference && item.b === code)
    if (!pair) throw new Error('PLANNED_PAIR_MISSING')
    const reverse = pair.a === reference
    return { ...pair, id: `${code}/${reference}`, a: code, b: reference,
      estimate: pair.estimate === null ? null : reverse ? -pair.estimate : pair.estimate,
      lower: pair.lower === null || pair.upper === null ? null : reverse ? -pair.upper : pair.lower,
      upper: pair.lower === null || pair.upper === null ? null : reverse ? -pair.lower : pair.upper }
  })
}
