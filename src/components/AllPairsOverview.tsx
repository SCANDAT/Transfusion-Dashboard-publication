import { useEffect, useState } from 'react'
import { type FitKey, type ReleaseJob, type ValidatedRelease } from '../data/release'
import { COMPONENT_FACTOR_ORDER, FACTOR_LABELS, OUTCOME_META, categoryLabel, PARITY_NOTE, MODEL_LABELS, POPULATION_LABELS } from '../data/display'
import { loadTable } from '../data/loader'
import { overallProbability, type DisplayComparisonLoader, type DisplayComparison } from '../data/componentDisplay'
import { readComparison, type ComponentComparison } from '../data/comparisons'
import { displayPairs } from '../data/pairwiseDisplay'
import { isWeekdayPlan } from '../data/weekday'
import ForestPlot, { type ForestRow } from './ForestPlot'
import './allPairsOverview.css'

type Factor = Exclude<FitKey['factor'], 'MAIN'>
export interface AllPairsOverviewProps {
  displayReleaseId?: string; loadDisplay?: DisplayComparisonLoader
  release: ValidatedRelease | null; assetBase: string; releaseError: boolean
  model: FitKey['model']; population: FitKey['population']; outcome: FitKey['outcome']
  onExplore?: (key: FitKey) => void
}
interface Group { state: 'loading' | 'accepted' | 'unavailable'; message?: string; rows?: readonly ForestRow[]; result?: ComponentComparison | DisplayComparison }
const ORDER = COMPONENT_FACTOR_ORDER
function unavailable(job: ReleaseJob | undefined): string {
  if (!job || job.state === 'pending') return 'Not yet available.'
  if (job.state === 'failed') return 'Result unavailable.'
  return 'Statistical inference is unavailable for this analysis.'
}


/** Complete exported A-minus-B families for one outcome; no reference reorientation. */
export default function AllPairsOverview({ release, assetBase, releaseError, model, population, outcome, onExplore, displayReleaseId, loadDisplay }: AllPairsOverviewProps) {
  const scope = `${displayReleaseId ?? release?.manifest.releaseId}/${assetBase}/${population}/${model}/${outcome}`
  const [loaded, setLoaded] = useState<{ release: ValidatedRelease | null; scope: string; groups: Partial<Record<Factor, Group>> }>({ release: null, scope: '', groups: {} })
  const groups = loaded.release === release && loaded.scope === scope ? loaded.groups : {}
  useEffect(() => {
    if ((!release && !displayReleaseId) || releaseError) return
    const controller = new AbortController()
    setLoaded({ release, scope, groups: {} })
    const store = (factor: Factor, group: Group) => {
      if (!controller.signal.aborted) setLoaded(previous => previous.release === release && previous.scope === scope
        ? { ...previous, groups: { ...previous.groups, [factor]: group } } : previous)
    }
    for (const factor of ORDER) {
      const key: FitKey = { population, model, outcome, factor }
      const job = release?.manifest.jobs.find(job => job.key.population === population && job.key.model === model && job.key.outcome === outcome && job.key.factor === factor)
      // Weekday tables also carry the five-day model and contrast-family identifiers.
      if (!displayReleaseId && factor === 'wdy_donation' && (!job || !isWeekdayPlan(job.plan.categoryCodes))) { store(factor, { state: 'unavailable', message: 'Ten Monday-to-Friday comparisons await validated results.' }); continue }
      if (!displayReleaseId && (!job || job.state !== 'accepted')) { store(factor, { state: 'unavailable', message: unavailable(job) }); continue }
      store(factor, { state: 'loading' })
      const loadedComparison = displayReleaseId
        ? loadDisplay?.(key, controller.signal) ?? Promise.reject(new Error('Display loader unavailable'))
        : Promise.all([
          loadTable(release!, key, 'within', assetBase, controller.signal),
          loadTable(release!, key, 'pairwise', assetBase, controller.signal),
          loadTable(release!, key, 'joint', assetBase, controller.signal),
        ]).then(([within, pairs, joint]) => {
          controller.signal.throwIfAborted()
          return readComparison(within, pairs, joint, job!.plan)
        })
      loadedComparison.then(result => {
        if (controller.signal.aborted) return
        const rows = displayPairs(result, null).map(pair => ({ id: pair.id,
          label: `${categoryLabel(factor, pair.a)} versus ${categoryLabel(factor, pair.b)}`,
          comparison: { first: categoryLabel(factor, pair.a), second: categoryLabel(factor, pair.b) },
          estimate: pair.estimate, lower: pair.lower, upper: pair.upper, holmP: pair.holmP,
          unavailableLabel: 'Unavailable',
        }))
        store(factor, { state: 'accepted', result, rows })
      }).catch(() => { if (!controller.signal.aborted) store(factor, { state: 'unavailable', message: 'These comparisons could not be verified or loaded.' }) })
    }
    return () => controller.abort()
  }, [release, displayReleaseId, loadDisplay, assetBase, releaseError, model, population, outcome, scope])
  if (releaseError) return <div className="error" role="status">Results could not be loaded.</div>
  if (!release && !displayReleaseId) return <p role="status">Loading comparisons...</p>
  const hasLowDfOverallTest = ORDER.some(factor => {
    const group = groups[factor], test = group?.result?.tests.find(item => item.kind === 'endpoint')
    return group?.state === 'accepted' && test?.status === 'LOW_EFFECTIVE_DF' && test.pValue != null
  })
  const meta = OUTCOME_META[outcome]
  const values = Object.values(groups).flatMap(group => (group.rows ?? []).flatMap(row => [row.estimate, row.lower, row.upper])).filter((value): value is number => value !== null && Number.isFinite(value))
  const extent = Math.max(...values.map(Math.abs), .01) * 1.12
  const step = 10 ** Math.floor(Math.log10(extent)), sharedBound = Math.ceil(extent / step) * step
  const dialogContext = <><p>{MODEL_LABELS[model]}; {POPULATION_LABELS[population]}. Change from 1 hour before to 1 hour after transfusion. First named group minus second; the complete Holm comparison family is unchanged.</p>{(outcome === 'FIO2' || outcome === 'SPO2') && <p>Changes are absolute percentage-point differences, not relative percentage changes.</p>}</>
  return <section className="all-pairs-overview" aria-label={`${meta.name}: all donor and component comparisons`}>
    <p className="all-pairs-definition">Change is the predicted value one hour after minus one hour before transfusion. Each comparison is the first named group minus the second. Positive values indicate a more positive change in the first group.</p>
    <p className="all-pairs-scroll-note">Scroll panels horizontally for all columns.</p>
    <div className="all-pairs-grid">
      {ORDER.map(factor => {
        const group = groups[factor], title = FACTOR_LABELS[factor], overall = group?.result?.tests.find(test => test.kind === 'endpoint')
        return <section className={`all-pairs-card${factor === 'DonorHb_Cat' || factor === 'Storage_Cat' ? ' all-pairs-card-wide' : ''}`} key={factor} data-factor={factor} aria-label={title} tabIndex={0}>
          <div className="all-pairs-card-heading"><h3>{title}{factor === 'wdy_donation' && <small>Monday to Friday</small>}</h3>
            {group?.state === 'accepted' && <span className="all-pairs-overall" title="Overall equality of category changes; unadjusted across factors and outcomes">Overall p {overallProbability(overall?.pValue)}{overall?.status === 'LOW_EFFECTIVE_DF' && overall.pValue != null ? '†' : ''}</span>}
          </div>
          {group?.state === 'accepted' && group.rows ? <>
            <ForestPlot rows={group.rows} title={`${meta.name}: ${title}, all pairwise differences`} unit={meta.changeUnit} color={meta.color} zeroLabel="equal changes" showHolm stackComparisonLabels rowHeading="First group vs second" showLegend={false} axisBound={sharedBound} context={dialogContext}/>
            {onExplore && <button type="button" className="all-pairs-details" onClick={() => onExplore({ population, model, outcome, factor })}>Reference comparisons</button>}
          </> : <p className="all-pairs-unavailable" role="status">{group?.state === 'unavailable' ? group.message : 'Loading comparisons...'}</p>}
        </section>
      })}
    </div>
    <p className="all-pairs-note">Dots show estimates; bars show pointwise 95% confidence intervals. All factors use the same horizontal scale for this outcome. Holm p values retain the complete comparison family for each factor and outcome; intervals are not adjusted for multiple comparisons. Overall p values test equality of category changes and are unadjusted across factors and outcomes.{hasLowDfOverallTest && ' A dagger (†) denotes low effective degrees of freedom.'}</p>
    <p className="all-pairs-note">{PARITY_NOTE} Donation-day comparisons cover Monday to Friday; weekend observations remain in model estimation and count tables. FiO2 and SpO2 changes are absolute percentage-point differences.</p>
  </section>
}
