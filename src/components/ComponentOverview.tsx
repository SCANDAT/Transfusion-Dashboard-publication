import { useEffect, useId, useMemo, useState } from 'react'
import { type FitKey, type ReleaseJob, type ValidatedRelease } from '../data/release'
import { COMPONENT_FACTOR_ORDER, FACTOR_LABELS, OUTCOME_META, OUTCOME_HEADING_LINES, PANEL_ORDER, MODEL_LABELS, POPULATION_LABELS, UNAVAILABLE_REASON_LABELS, PARITY_NOTE, DONATION_DAY_COMPARISON_CODES, DONATION_DAY_PENDING_NOTE, categoryLabel } from '../data/display'
import { loadTable } from '../data/loader'
import { componentCategories, overallProbability, type DisplayComparison, type DisplayComparisonLoader } from '../data/componentDisplay'
import { readComparison, type ComponentComparison } from '../data/comparisons'
import { displayPairs, type DisplayPair } from '../data/pairwiseDisplay'
import { formatValue } from './trajectoryGeometry'
import './componentOverview.css'
import SummaryDownload from './SummaryDownload'
import { componentSummarySvg } from '../figures/summarySvg'

type Factor = Exclude<FitKey['factor'], 'MAIN'>
interface Props {
  displayReleaseId?: string
  loadDisplay?: DisplayComparisonLoader
  release: ValidatedRelease | null
  assetBase: string
  releaseError: boolean
  model: FitKey['model']
  population: FitKey['population']
  onExplore: (key: FitKey, referenceCode: string) => void
}
interface Cell { result?: ComponentComparison | DisplayComparison; message?: string }
interface Loaded {
  release: ValidatedRelease | null
  scope: string
  cells: Readonly<Record<string, Cell>>
  completed: number
  total: number
}
const FACTOR_ORDER = COMPONENT_FACTOR_ORDER
const REQUEST_WORKERS = 4
const CATEGORY_ROW_HEIGHT = 20
const CATEGORY_POINT_OFFSET = 12
function cellId(factor: Factor, outcome: FitKey['outcome']) { return `${factor}/${outcome}` }
function unavailability(job: ReleaseJob | undefined): string {
  if (!job || job.state === 'pending') return 'Results are not yet available.'
  if (job.state === 'failed') return 'Result unavailable.'
  if (job.state === 'inference_unavailable') {
    if (job.reasonCode === 'PLANNED_TARGET_NOT_LOO_ESTIMABLE') return 'Planned comparisons are not supported after leaving out an individual patient.'
    if (Object.prototype.hasOwnProperty.call(UNAVAILABLE_REASON_LABELS, job.reasonCode)) {
      return UNAVAILABLE_REASON_LABELS[job.reasonCode as keyof typeof UNAVAILABLE_REASON_LABELS]
    }
    return 'The required statistical inference is unavailable.'
  }
  return ''
}
function plotBound(rows: readonly DisplayPair[]): number | null {
  const values = rows.flatMap(row => [row.lower, row.estimate, row.upper]).filter((value): value is number => value !== null && Number.isFinite(value))
  if (!values.length) return null
  const span = Math.max(...values.map(Math.abs), 0.001) * 1.08
  const step = 10 ** Math.floor(Math.log10(span))
  return Math.ceil(span / step) * step
}
function tick(value: number) { return value.toLocaleString('en-GB', { maximumSignificantDigits: 3 }) }
function pointX(value: number, bound: number) { return 12 + (value + bound) / (bound * 2) * 104 }
function pairDescription(factor: Factor, pair: DisplayPair, unit: string): string {
  return `${categoryLabel(factor, pair.a)} versus ${categoryLabel(factor, pair.b)}: ${pair.estimate === null
    ? 'unavailable'
    : `${formatValue(pair.estimate, 4)}; 95% confidence interval ${formatValue(pair.lower, 4)} to ${formatValue(pair.upper, 4)} ${unit}`}.`
}

export default function ComponentOverview({ release, assetBase, releaseError, model, population, onExplore, displayReleaseId, loadDisplay }: Props) {
  const id = useId()
  const scope = `${displayReleaseId ?? release?.manifest.releaseId}/${assetBase}/${population}/${model}`
  const jobs = useMemo(() => {
    const selected = new Map<string, ReleaseJob>()
    for (const job of release?.manifest.jobs ?? []) {
      if (job.key.population === population && job.key.model === model && job.key.factor !== 'MAIN') {
        selected.set(cellId(job.key.factor, job.key.outcome), job)
      }
    }
    return selected
  }, [release, model, population])
  const plans = useMemo(() => Object.fromEntries(FACTOR_ORDER.map(factor => {
    const job = PANEL_ORDER.map(outcome => jobs.get(cellId(factor, outcome))).find(value => value !== undefined)
    if (displayReleaseId) return [factor, componentCategories[factor]]
    return [factor, factor === 'wdy_donation' ? DONATION_DAY_COMPARISON_CODES : job?.plan.categoryCodes ?? []]
  })) as Record<Factor, readonly string[]>, [jobs, displayReleaseId])
  const [loaded, setLoaded] = useState<Loaded>({ release: null, scope: '', cells: {}, completed: 0, total: 0 })
  const current = loaded.scope === scope && loaded.release === release ? loaded : undefined

  useEffect(() => {
    if ((!release && !displayReleaseId) || releaseError) return
    const controller = new AbortController()
    const cells: Record<string, Cell> = {}
    const queue: {name:string; key:FitKey; job?:ReleaseJob}[] = displayReleaseId
      ? FACTOR_ORDER.flatMap(factor => PANEL_ORDER.map(outcome => ({
        name:cellId(factor,outcome), key:{population, model, factor, outcome},
      })))
      : [...jobs.entries()].filter(([,job]) => job.state === 'accepted').map(([name,job]) => ({name,key:job.key,job}))
    let cursor = 0
    let completed = 0
    setLoaded({ release, scope, cells: {}, completed, total: queue.length })
    async function worker() {
      while (!controller.signal.aborted) {
        const item = queue[cursor++]
        if (!item) return
        const {name:key, job, key:fit} = item
        const factor = fit.factor as Factor
        if (job && job.plan.categoryCodes.join('/') !== plans[factor].join('/')) {
          cells[key] = { message: factor === 'wdy_donation' ? DONATION_DAY_PENDING_NOTE : 'The comparison categories could not be verified.' }
        } else {
          try {
            let result: ComponentComparison | DisplayComparison
            if (displayReleaseId && loadDisplay) {
              result = await loadDisplay(fit, controller.signal)
            } else if (!displayReleaseId && release && job) {
              const [within,pairwise,joint] = await Promise.all([
                loadTable(release, fit, 'within', assetBase, controller.signal),
                loadTable(release, fit, 'pairwise', assetBase, controller.signal),
                loadTable(release, fit, 'joint', assetBase, controller.signal),
              ])
              if (controller.signal.aborted) return
              result = readComparison(within, pairwise, joint, job.plan)
            } else throw new Error('Display loader unavailable')
            if (controller.signal.aborted) return
            cells[key] = {result}
          } catch {
            if (controller.signal.aborted) return
            cells[key] = { message: 'These comparisons could not be verified or loaded.' }
          }
        }
        completed += 1
        if (!controller.signal.aborted) setLoaded({ release, scope, cells: {}, completed, total: queue.length })
      }
    }
    // Set the common column scales once all plots have loaded.
    Promise.all(Array.from({ length: Math.min(REQUEST_WORKERS, queue.length) }, worker)).then(() => {
      if (!controller.signal.aborted) setLoaded({ release, scope, cells, completed, total: queue.length })
    })
    return () => controller.abort()
  }, [release, releaseError, displayReleaseId, loadDisplay, population, model, assetBase, scope, jobs, plans])

  const rowsFor = (factor: Factor, outcome: FitKey['outcome']) => {
    const result = current?.cells[cellId(factor, outcome)]?.result
    return result ? displayPairs(result, plans[factor][0] ?? null) : []
  }
  const bounds = Object.fromEntries(PANEL_ORDER.map(outcome => [
    outcome, plotBound(FACTOR_ORDER.flatMap(factor => rowsFor(factor, outcome))),
  ])) as Record<FitKey['outcome'], number | null>
  const hasLowDfOverallTest = FACTOR_ORDER.some(factor => PANEL_ORDER.some(outcome => {
    const test = current?.cells[cellId(factor, outcome)]?.result?.tests.find(item => item.kind === 'endpoint')
    return test?.status === 'LOW_EFFECTIVE_DF' && test.pValue !== null && test.pValue !== undefined
  }))
  const busy = Boolean((release || displayReleaseId) && !releaseError && (!current || current.completed < current.total))
  const exportReady = Boolean(!releaseError && !busy && (displayReleaseId
    ? current && Object.values(current.cells).length === FACTOR_ORDER.length*PANEL_ORDER.length && Object.values(current.cells).every(cell=>cell.result)
    : release?.manifest.datasetKind === 'full_cohort'))
  function exportOverview() {
    if ((!release && !displayReleaseId) || !exportReady) throw new Error('FIGURE_SCOPE_NOT_READY')
    return componentSummarySvg({ releaseId: displayReleaseId ?? release!.manifest.releaseId, datasetKind: displayReleaseId ? 'display' : 'full_cohort', compact: Boolean(displayReleaseId), population, model,
      factors: FACTOR_ORDER.map(factor => ({ factor, categoryCodes: plans[factor], cells: PANEL_ORDER.map(outcome => {
        const job = jobs.get(cellId(factor, outcome)), cell = current?.cells[cellId(factor, outcome)]
        const deferred = !displayReleaseId && factor === 'wdy_donation' && (!job || job.plan.categoryCodes.join('/') !== DONATION_DAY_COMPARISON_CODES.join('/'))
        return { outcome, state: deferred ? 'pending' : cell?.result ? 'accepted' : (displayReleaseId || job?.state === 'accepted') ? 'failed' : job?.state ?? 'pending',
          result: deferred ? undefined : cell?.result, message: deferred ? DONATION_DAY_PENDING_NOTE : cell?.message ?? unavailability(job) }
      }) })),
    })
  }
  if (releaseError) return <div className="error" role="status">Results could not be loaded.</div>
  if (!release && !displayReleaseId) return <div className="component-overview-loading" role="status">Loading comparisons...</div>

  return <section className="component-overview" aria-labelledby={`${id}-title`}>
    <div className="component-overview-heading">
      <div><h3 id={`${id}-title`}>Differences in change across vital parameters</h3>
      <p className="component-overview-scope">{MODEL_LABELS[model]} | {POPULATION_LABELS[population]} | All donor and component factors</p></div>
      <SummaryDownload ready createSvg={exportOverview} filename={`component-comparisons-${population.toLowerCase()}-${model.toLowerCase()}.svg`} disabled={!exportReady}/>
    </div>
    {busy && <p className="component-overview-progress" role="status">Loading comparisons{current?.total ? ` (${current.completed} of ${current.total})` : ''}...</p>}
    <div className="component-overview-scroll" role="region" tabIndex={0} aria-label="Overview of donor and component differences in change" aria-describedby={`${id}-key ${id}-instruction`} aria-busy={busy}>
      <table className="component-overview-table">
        <caption className="component-overview-accessible">Category minus reference differences in change. Select a factor and outcome to explore the complete comparisons.</caption>
        <colgroup><col className="component-overview-label-column"/>{PANEL_ORDER.map(outcome => <col key={outcome}/>)}</colgroup>
        <thead><tr><th scope="col">Category</th>{PANEL_ORDER.map(outcome => {
          const meta = OUTCOME_META[outcome]
          return <th scope="col" key={outcome}><strong style={{ color: meta.color }}>{meta.shortName}</strong><span className="component-overview-outcome-name">{OUTCOME_HEADING_LINES[outcome].map((line, index) => <span key={line}>{line}{index === 0 ? ' ' : ''}</span>)}</span><span className="component-overview-unit">{meta.changeUnit}</span></th>
        })}</tr></thead>
        {FACTOR_ORDER.map(factor => {
          const codes = plans[factor]
          const reference = codes[0]
          const weekdayUnavailable = !displayReleaseId && factor === 'wdy_donation' && !PANEL_ORDER.some(outcome => current?.cells[cellId(factor, outcome)]?.result)
          const height = weekdayUnavailable ? 24 : Math.max(codes.length * CATEGORY_ROW_HEIGHT, 36) + 4
          return <tbody key={factor}>
            <tr className="component-overview-factor"><th scope="rowgroup"><span className="component-overview-factor-heading"><span>{FACTOR_LABELS[factor]}</span></span></th>{PANEL_ORDER.map(outcome => {
              const test = current?.cells[cellId(factor, outcome)]?.result?.tests.find(item => item.kind === 'endpoint')
              const pending = !displayReleaseId && factor === 'wdy_donation' && !current?.cells[cellId(factor, outcome)]?.result
              const available = !pending && test?.pValue !== null && test?.pValue !== undefined && (test.status === 'COMPUTED' || test.status === 'LOW_EFFECTIVE_DF')
              return <td key={outcome}><span className="component-overview-overall" data-p-value={available && !displayReleaseId ? test.pValue : undefined}
                title={pending ? DONATION_DAY_PENDING_NOTE : available ? `Overall equality of category changes; unadjusted across factors and outcomes${test.status === 'LOW_EFFECTIVE_DF' ? '; low effective degrees of freedom' : ''}` : 'Overall test unavailable'}>
                {available ? `p ${overallProbability(test.pValue)}${test.status === 'LOW_EFFECTIVE_DF' ? '†' : ''}` : pending ? '—' : 'p unavailable'}
              </span></td>
            })}</tr>
            <tr>
              <th scope="row" className="component-overview-category-list"><span className="component-overview-accessible">{FACTOR_LABELS[factor]} categories: </span><ul style={{ minHeight: height }}>{weekdayUnavailable ? <li>Monday to Friday</li> : codes.map(code => <li key={code} className={code === reference ? 'component-reference-label' : undefined}>{categoryLabel(factor, code)}{code === reference && ' (reference)'}</li>)}</ul></th>
              {PANEL_ORDER.map(outcome => {
                const key = cellId(factor, outcome), job = jobs.get(key), meta = OUTCOME_META[outcome]
                const cell = current?.cells[key]
                const rows = rowsFor(factor, outcome)
                const bound = bounds[outcome]
                const deferred = !displayReleaseId && factor === 'wdy_donation' && !cell?.result && (!job || job.state !== 'accepted' || job.plan.categoryCodes.join('/') !== DONATION_DAY_COMPARISON_CODES.join('/'))
                const unavailable = !displayReleaseId && (!job || job.state !== 'accepted')
                const message = deferred ? DONATION_DAY_PENDING_NOTE : unavailable ? unavailability(job) : cell?.message
                const descriptionId = `${id}-${factor}-${outcome}`
                const hasReference = Boolean(cell?.result?.activeCategoryCodes.includes(reference!) && cell.result.categories.some(category => category.code === reference && category.status === 'COMPUTED'))
                const description = (hasReference ? `${categoryLabel(factor, reference!)}: reference; zero by definition, with no confidence interval or p value. ` : '') + (rows.length ? rows.map(row => pairDescription(factor, row, meta.changeUnit)).join(' ') : message ?? 'Loading comparisons.')
                return <td key={outcome}>
                  <button type="button" className="component-overview-panel" style={{ minHeight: height }}
                    disabled={(!displayReleaseId && !job) || reference === undefined}
                    aria-label={`Explore ${FACTOR_LABELS[factor]}: ${meta.name}`}
                    aria-describedby={descriptionId}
                    onClick={() => reference !== undefined && onExplore({ population, model, factor, outcome }, reference)}>
                    {message ? <span className="component-overview-unavailable"><strong>{deferred ? 'Pending' : !displayReleaseId && (job?.state === 'pending' || !job) ? 'Not yet available' : 'Unavailable'}</strong><span className={deferred ? 'component-overview-accessible' : undefined}>{message}</span></span>
                      : !cell?.result ? <span className="component-overview-cell-loading">Loading...</span>
                        : <svg viewBox={`0 0 128 ${height}`} height={height} preserveAspectRatio="none" aria-hidden="true">
                          {bound !== null && <line x1={pointX(0, bound)} x2={pointX(0, bound)} y1={4} y2={height - 4} className="component-overview-zero" vectorEffect="non-scaling-stroke"/>}
                          {hasReference && <g className="component-overview-reference" data-category-code={reference}>
                            <title>{categoryLabel(factor, reference!)}: reference; zero by definition, with no confidence interval or p value.</title>
                            <path d={`M64,${CATEGORY_POINT_OFFSET}h0.001`} stroke="#78847f" strokeWidth={7} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
                            <path d={`M64,${CATEGORY_POINT_OFFSET}h0.001`} stroke="white" strokeWidth={4} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
                          </g>}
                          {rows.map((row, index) => {
                            const y = CATEGORY_POINT_OFFSET + (index + 1) * CATEGORY_ROW_HEIGHT
                            return row.estimate !== null && row.lower !== null && row.upper !== null && bound !== null
                              ? <g key={row.id} className="component-overview-estimate" data-estimate={row.estimate} data-lower={row.lower} data-upper={row.upper} data-holm-p={row.holmP}>
                                  <title>{pairDescription(factor, row, meta.changeUnit)}</title>
                                  <line x1={pointX(row.lower, bound)} x2={pointX(row.upper, bound)} y1={y} y2={y} stroke={meta.color} strokeWidth={1.7} vectorEffect="non-scaling-stroke"/>
                                  <line x1={pointX(row.lower, bound)} x2={pointX(row.lower, bound)} y1={y - 3} y2={y + 3} stroke={meta.color} vectorEffect="non-scaling-stroke"/>
                                  <line x1={pointX(row.upper, bound)} x2={pointX(row.upper, bound)} y1={y - 3} y2={y + 3} stroke={meta.color} vectorEffect="non-scaling-stroke"/>
                                  <path d={`M${pointX(row.estimate, bound)},${y}h0.001`} stroke={meta.color} strokeWidth={6} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
                                </g>
                              : <text key={row.id} x={64} y={y + 3} textAnchor="middle" className="component-overview-missing"><title>{pairDescription(factor, row, meta.changeUnit)}</title>—</text>
                          })}
                        </svg>}
                    <span id={descriptionId} className="component-overview-accessible">{description}</span>
                  </button>
                </td>
              })}
            </tr>
          </tbody>
        })}
        <tfoot><tr><th scope="row">Difference in change</th>{PANEL_ORDER.map(outcome => {
          const bound = bounds[outcome]
          return <td key={outcome}>{bound === null ? <span className="component-overview-no-scale">No estimates</span> : <svg viewBox="0 0 128 26" height={26} preserveAspectRatio="none" aria-label={`Scale: ${tick(-bound)} to ${tick(bound)} ${OUTCOME_META[outcome].changeUnit}`} role="img">
            <line x1={12} x2={116} y1={3} y2={3} className="component-overview-axis" vectorEffect="non-scaling-stroke"/>
            {[-bound, 0, bound].map(value => <g key={value}><line x1={pointX(value, bound)} x2={pointX(value, bound)} y1={3} y2={7} className="component-overview-axis"/><text x={pointX(value, bound)} y={21} textAnchor={value < 0 ? 'start' : value > 0 ? 'end' : 'middle'}>{tick(value)}</text></g>)}
          </svg>}</td>
        })}</tr></tfoot>
      </table>
    </div>
    <div className="component-overview-explanation">
    <p className="component-overview-key">Estimates show differences between category-specific changes from −1 to +1 hour and the reference-category change.</p>
    <p className="component-overview-key" id={`${id}-key`}>Bars: pointwise 95% CIs. Open circles: reference (zero). Overall p values test equality of category changes; unadjusted across factors and outcomes.</p>
    <p className="component-overview-instruction" id={`${id}-instruction`}>Select a panel for all pairwise comparisons.</p>
    </div>
    <details className="component-overview-notes"><summary>Units and comparison definitions</summary>
      {hasLowDfOverallTest && <p>A dagger (†) denotes low effective degrees of freedom for the overall test.</p>}
      <p>Positive estimates indicate a greater increase or smaller decrease than in the reference category. Scales are shared within each outcome column.</p>
      <p>Detailed pairwise p values are Holm-adjusted within each factor–outcome–model–population family. Confidence intervals are pointwise and are not adjusted for multiple comparisons.</p>
      <p>Oxygen changes are absolute percentage-point differences, not relative percentages.</p>
      <p><strong>FiO₂.</strong> {OUTCOME_META.FIO2.unitNote}</p>
      <p><strong>Minute ventilation.</strong> {OUTCOME_META.VE.unitNote}</p>
      <p><strong>Donor parity.</strong> {PARITY_NOTE}</p>
    </details>
  </section>
}
