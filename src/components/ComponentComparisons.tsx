import { useEffect, useRef, useState } from 'react'
import { OUTCOMES, POPULATIONS, type FitKey, type ValidatedRelease } from '../data/release'
import { COMPONENT_FACTOR_ORDER, FACTOR_LABELS, FULL_MODEL_NOTE, MODEL_LABELS, OUTCOME_META, POPULATION_LABELS, PARITY_NOTE, DONATION_DAY_PENDING_NOTE, PANEL_ORDER, categoryLabel } from '../data/display'
import { loadTable } from '../data/loader'
import { readComparison } from '../data/comparisons'
import { componentCategories, componentDisplayKey, formatProbability, validateComponentDisplay, type DisplayComparison, type DisplayComparisonLoader } from '../data/componentDisplay'
import { isWeekdayPlan } from '../data/weekday'
import { formatValue } from './trajectoryGeometry'
import ForestPlot from './ForestPlot'
import { displayPairs } from '../data/pairwiseDisplay'
import ComponentOverview from './ComponentOverview'
import OptionsPanel from './OptionsPanel'
import AllPairsOverview from './AllPairsOverview'

type Comparison = ReturnType<typeof readComparison> | DisplayComparison
type Factor = Exclude<FitKey['factor'], 'MAIN'>
type Props = { release: ValidatedRelease | null; assetBase: string; releaseError: boolean; displayReleaseId?: string }
const jointStatusLabels = { COMPUTED: '', LOW_EFFECTIVE_DF: 'Low effective degrees of freedom', INSUFFICIENT_EFFECTIVE_DF: 'Insufficient information for this test', NOT_APPLICABLE_SINGLE_CATEGORY: 'Only one category available', MOMENT_PRECISION_UNRESOLVED: 'Uncertainty could not be estimated reliably', DF2_SIGN_UNRESOLVED: 'Degrees of freedom unavailable' } as const
const componentFactors = COMPONENT_FACTOR_ORDER
function interval(lower: number | null, upper: number | null) {
  return lower === null || upper === null ? 'Unavailable' : `${formatValue(lower)} to ${formatValue(upper)}`
}

const loadDisplayComparison: DisplayComparisonLoader = async (key, signal) => {
  const logicalKey = componentDisplayKey(key)
  const { readDisplay } = await import('../data/reader')
  const data = await readDisplay(logicalKey, signal)
  signal.throwIfAborted()
  return validateComponentDisplay(logicalKey, data)
}

export default function ComponentComparisons({ release, assetBase, releaseError, displayReleaseId }: Props) {
  const [view, setView] = useState<'overview' | 'explore' | 'detail'>(() => {
    const query = new URLSearchParams(location.search)
    return query.get('comparison') === 'detail' || !query.has('comparison') && (query.has('factor') || query.has('outcome')) ? 'detail' : query.get('comparison') === 'explore' ? 'explore' : 'overview'
  })
  const detailControls = useRef<HTMLDivElement>(null)
  const focusSelection = useRef(false)
  const [outcome, setOutcome] = useState<FitKey['outcome']>(() => OUTCOMES.find(v => v === new URLSearchParams(location.search).get('outcome')) ?? 'ARTm')
  const [factor, setFactor] = useState<Factor>(() => componentFactors.find(v => v === new URLSearchParams(location.search).get('factor')) ?? 'Storage_Cat')
  const [model, setModel] = useState<FitKey['model']>(() => new URLSearchParams(location.search).get('model') === 'BASE' ? 'BASE' : 'FULL')
  const [population, setPopulation] = useState<FitKey['population']>(() => POPULATIONS.find(v => v === new URLSearchParams(location.search).get('population')) ?? 'PRIMARY')
  const [loaded, setLoaded] = useState<{ selection: string; result?: Comparison; message?: string }>({ selection: '' })
  const [reference, setReference] = useState<{ factor: Factor; code: string } | null>(null)
  const [allPairs, setAllPairs] = useState(false)
  const [showHolm, setShowHolm] = useState(false)
  const selection = `${displayReleaseId ?? release?.manifest.releaseId}/${population}/${model}/${factor}/${outcome}`
  const result = loaded.selection === selection ? loaded.result : undefined
  const message = loaded.selection === selection ? loaded.message : undefined
  const meta = OUTCOME_META[outcome]
  const orderedPairs = result ? displayPairs(result, null) : []
  const referenceCode = result ? reference?.factor === factor && result.plannedCategoryCodes.includes(reference.code) ? reference.code : result.plannedCategoryCodes[0]! : ''
  const plottedPairs = result ? displayPairs(result, allPairs ? null : referenceCode) : []


  useEffect(() => {
    if ((!release && !displayReleaseId) || releaseError || view !== 'detail') return
    const controller = new AbortController()
    const key: FitKey = { population, model, factor, outcome }
    if (displayReleaseId) {
      setLoaded({selection})
      loadDisplayComparison(key, controller.signal).then(result => {
        if (!controller.signal.aborted) setLoaded({selection, result})
      }).catch(() => {
        if (!controller.signal.aborted) setLoaded({selection, message:'These comparisons could not be verified or loaded.'})
      })
      return () => controller.abort()
    }
    if (!release) return
    const job = release.manifest.jobs.find(j => j.key.population === population && j.key.model === model && j.key.factor === factor && j.key.outcome === outcome)
    setLoaded({ selection })
    if (factor === 'wdy_donation' && (!job || !isWeekdayPlan(job.plan.categoryCodes))) {
      setLoaded({ selection, message: DONATION_DAY_PENDING_NOTE })
      return () => controller.abort()
    }
    if (!job || job.state !== 'accepted') {
      setLoaded({ selection, message: !job || job.state === 'pending' ? 'This comparison is not yet available.' : job.state === 'failed' ? 'This analysis has no accepted result.' : 'Inference is unavailable for this analysis.' })
      return () => controller.abort()
    }
    Promise.all([loadTable(release, key, 'within', assetBase, controller.signal), loadTable(release, key, 'pairwise', assetBase, controller.signal), loadTable(release, key, 'joint', assetBase, controller.signal)])
      .then(([within, pairwise, joint]) => {
        const parsed = readComparison(within, pairwise, joint, job.plan)
        if (!controller.signal.aborted) setLoaded({ selection, result: parsed })
      })
      .catch(() => { if (!controller.signal.aborted) setLoaded({ selection, message: 'These comparisons could not be verified or loaded.' }) })
    return () => controller.abort()
  }, [release, displayReleaseId, releaseError, outcome, factor, population, model, assetBase, selection, view])

  useEffect(() => {
    const url = new URL(location.href)
    url.searchParams.set('factor', factor); url.searchParams.set('outcome', outcome)
    url.searchParams.set('model', model); url.searchParams.set('population', population)
    url.searchParams.set('comparison', view)
    history.replaceState(null, '', url)
  }, [factor, outcome, model, population, view])

  useEffect(() => {
    if (view === 'detail' && focusSelection.current) {
      detailControls.current?.focus()
      focusSelection.current = false
    }
  }, [view, factor, outcome])

  function openComparison(key: FitKey, referenceCode: string) {
    setFactor(key.factor as Factor); setOutcome(key.outcome)
    setModel(key.model); setPopulation(key.population)
    setReference({ factor: key.factor as Factor, code: referenceCode })
    setAllPairs(false)
    focusSelection.current = true
    setView('detail')
  }

  return <div className="comparison-view">
    <div className="comparison-heading"><h2>Donor and component comparisons</h2>
    <div className="component-presentation-switch" role="group" aria-label="Comparison presentation">
      <button type="button" aria-pressed={view === 'overview'} onClick={() => setView('overview')}>Overview</button>
      <button type="button" aria-pressed={view !== 'overview'} onClick={() => setView('explore')}>Explore comparisons</button>
    </div></div>
    {view === 'detail' && <div className="controls comparison-controls primary-controls" ref={detailControls} tabIndex={-1} role="group" aria-label="Comparison selection">
      <label>Vital parameter<select aria-label="Vital parameter" value={outcome} onChange={event => setOutcome(event.target.value as FitKey['outcome'])}>{OUTCOMES.map(code => <option value={code} key={code}>{OUTCOME_META[code].name}</option>)}</select></label>
      <label>Donor or component factor<select aria-label="Donor or component factor" value={factor} onChange={event => setFactor(event.target.value as Factor)}>{componentFactors.map(code => <option value={code} key={code}>{FACTOR_LABELS[code]}</option>)}</select></label>
    </div>}
    {view === 'detail' && factor === 'DonorParity_Female' && <p className="report-note">{PARITY_NOTE}</p>}
    {view === 'detail' && factor === 'wdy_donation' && result && <p className="report-note">Donation-day comparisons cover Monday to Friday; weekend observations remain in model estimation and count tables.</p>}
    <OptionsPanel className="comparison-options" label="Comparison model and population" summary={`${MODEL_LABELS[model]}; ${POPULATION_LABELS[population]}`}>
      <div className="controls">
        <label>Model<select aria-label="Model" value={model} onChange={event => setModel(event.target.value as FitKey['model'])}>{(['FULL', 'BASE'] as const).map(code => <option value={code} key={code}>{code === 'FULL' ? 'Full (primary)' : 'Base (comparison)'}</option>)}</select></label>
        <label>Analysis population<select aria-label="Analysis population" value={population} onChange={event => setPopulation(event.target.value as FitKey['population'])}>{POPULATIONS.map(code => <option value={code} key={code}>{POPULATION_LABELS[code]}</option>)}</select></label>
      </div>
    </OptionsPanel>
    {view === 'detail' && <button type="button" className="text-button" onClick={() => setView('explore')}>All pairwise comparisons for this vital parameter</button>}
    {view === 'overview' ? <ComponentOverview displayReleaseId={displayReleaseId} loadDisplay={loadDisplayComparison} release={release} assetBase={assetBase} releaseError={releaseError} model={model} population={population} onExplore={openComparison}/> : view === 'explore' ? <>
      <div className="outcome-pills" role="group" aria-label="Vital parameter">
        {PANEL_ORDER.map(code => <button type="button" key={code} aria-label={OUTCOME_META[code].name} aria-pressed={outcome === code} title={OUTCOME_META[code].name}
          style={{ color: OUTCOME_META[code].color, borderColor: outcome === code ? OUTCOME_META[code].color : undefined, backgroundColor: outcome === code ? `${OUTCOME_META[code].color}12` : undefined }}
          onClick={() => setOutcome(code)}>{OUTCOME_META[code].shortName}</button>)}
        <span>{meta.name} &middot; {meta.changeUnit}</span>
      </div>
      <AllPairsOverview displayReleaseId={displayReleaseId} loadDisplay={loadDisplayComparison} release={release} assetBase={assetBase} releaseError={releaseError} model={model} population={population} outcome={outcome}
        onExplore={key => {
          const job = release?.manifest.jobs.find(item => item.key.population === key.population && item.key.model === key.model && item.key.factor === key.factor && item.key.outcome === key.outcome)
          const first = displayReleaseId ? componentCategories[key.factor as Factor][0] : job?.plan.categoryCodes[0]
          if (first !== undefined) openComparison(key, first)
        }}/>
    </> : releaseError || message ? <div className="error" role="status">{releaseError ? 'Results could not be loaded.' : message}</div> : !result ? <div className="card-empty" role="status">Loading comparisons...</div> : <>
      <section className="comparison-section" aria-labelledby="pairwise-title"><div className="section-title"><div><h3 id="pairwise-title">Difference in change</h3><p>{meta.name} &middot; {meta.changeUnit}</p></div></div>
        <div className="contrast-controls">
          {!allPairs && <label className="compact-control">Compare each category with<select aria-label="Compare each category with" value={referenceCode} onChange={event => setReference({ factor, code: event.target.value })}>{result.plannedCategoryCodes.map(code => <option value={code} key={code}>{categoryLabel(factor, code)}</option>)}</select></label>}
          <label className="checkbox-control"><input type="checkbox" checked={allPairs} onChange={event => setAllPairs(event.target.checked)}/>Show all pairs</label>
          <label className="checkbox-control"><input type="checkbox" checked={showHolm} onChange={event => setShowHolm(event.target.checked)}/>Show adjusted p values</label>
        </div>
        <p className="contrast-definition">{allPairs ? 'Each comparison is the change in the first group minus the change in the second group.' : <>Each comparison is the change in the displayed group minus the change for <strong>{categoryLabel(factor, referenceCode)}</strong>.</>} Change is the predicted value one hour after transfusion minus the predicted value one hour before transfusion.</p>
        <ForestPlot context={`${meta.name}; ${FACTOR_LABELS[factor]}; ${MODEL_LABELS[model]}; ${POPULATION_LABELS[population]}; change from 1 h before to 1 h after transfusion${outcome === 'FIO2' || outcome === 'SPO2' ? '; absolute percentage-point differences, not relative percentages' : ''}`} title="Differences between category changes" rowHeading={allPairs ? 'Comparison' : 'Group'} unit={meta.changeUnit} color={meta.color} zeroLabel="no difference in change" showHolm={showHolm} reference={!allPairs && result.activeCategoryCodes.includes(referenceCode) && result.categories.some(category => category.code === referenceCode && category.status === 'COMPUTED') ? { label: categoryLabel(factor, referenceCode) } : undefined} rows={plottedPairs.map(pair => ({ id: pair.id, label: allPairs ? `${categoryLabel(factor, pair.a)} versus ${categoryLabel(factor, pair.b)}` : categoryLabel(factor, pair.a), estimate: pair.estimate, lower: pair.lower, upper: pair.upper, holmP: pair.holmP }))}/>
        <p className="table-note">Confidence intervals are pointwise. Holm adjustment covers the complete comparison family ({result.pairs.length} comparisons), regardless of the rows displayed. A positive value means a greater rise or a smaller fall in the first group than in the second; a negative value means the reverse.</p>
        <details className="table-details"><summary>All pairwise estimates and p values</summary>
          <p className="table-scroll-hint" id="pairwise-scroll-hint">Scroll horizontally for all columns.</p>
          <div className="table-scroll" tabIndex={0} role="region" aria-label="Pairwise differences in change" aria-describedby="pairwise-scroll-hint"><table className="comparison-table"><thead><tr><th scope="col">First group</th><th scope="col">Second group</th><th scope="col">Difference in change</th><th scope="col">95% CI</th><th scope="col">p value</th><th scope="col">Holm-adjusted p</th></tr></thead><tbody>{orderedPairs.map(pair => <tr key={pair.id}><th scope="row">{categoryLabel(factor, pair.a)}</th><td>{categoryLabel(factor, pair.b)}</td><td>{formatValue(pair.estimate)}</td><td>{interval(pair.lower, pair.upper)}</td><td>{formatProbability(pair.pValue)}</td><td>{formatProbability(pair.holmP)}</td></tr>)}</tbody></table></div>
        </details>
      </section>
      <details className="comparison-section supporting-section"><summary>Change within each category</summary><p className="contrast-definition">The −1 to +1 hour change in each category, before taking differences between categories.</p>
        <ForestPlot context={`${meta.name}; ${FACTOR_LABELS[factor]}; ${MODEL_LABELS[model]}; ${POPULATION_LABELS[population]}; change from 1 h before to 1 h after transfusion${outcome === 'FIO2' || outcome === 'SPO2' ? '; absolute percentage-point differences, not relative percentages' : ''}`} title="Change within each category" unit={meta.changeUnit} color={meta.color} zeroLabel="no change" rows={result.categories.map(category => ({ id: category.code, label: categoryLabel(factor, category.code), estimate: category.estimate, lower: category.lower, upper: category.upper }))}/>
      </details>
      <section className="overall-section" aria-labelledby="overall-heading"><h3 id="overall-heading">Overall comparisons</h3><div className="joint-tests">{(['endpoint', 'trajectory'] as const).map(kind => {
        const test = result.tests.find(item => item.kind === kind)
        return <section className="joint-test" key={kind}><div><h4>{kind === 'endpoint' ? 'Changes from −1 to +1 hour' : 'Changes across the trajectory'}</h4><p>{kind === 'endpoint' ? 'Tests whether the changes from one hour before to one hour after transfusion are equal across categories.' : 'Tests whether category changes are equal over the modeled time course.'}</p></div><div className="test-value"><span>p value</span><strong>{formatProbability(test?.pValue ?? null)}</strong>{test && test.status !== 'COMPUTED' && <small>{jointStatusLabels[test.status]}</small>}</div></section>
      })}</div></section>
      <details className="method-note"><summary>Interpretation and statistical methods</summary><p>Changing the reference category changes the direction of the displayed comparisons, but not the fitted model or the Holm comparison family.</p><p>Holm adjustment is within this factor, outcome, model and population, not across the entire study. Pointwise confidence intervals and adjusted p values answer different inferential questions. Overall tests are reported separately.</p><p>Unavailable categories remain listed. These estimates describe adjusted associations, not causal effects of component characteristics.</p>{model === 'FULL' && <p>{FULL_MODEL_NOTE}</p>}</details>
    </>}
  </div>
}
