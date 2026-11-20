import { Fragment, useEffect, useMemo, useState } from 'react'
import { OUTCOMES, POPULATIONS, type FitKey } from './data/release'
import { isWithheld, openReader, readDisplay } from './data/reader'
import { displayEndpoints, displayTrajectory } from './data/mainDisplay'
import { type TrajectoryPoint } from './data/tables'
import { FULL_MODEL_NOTE, REFERENCE_PROFILE_NOTE, MODEL_LABELS, OUTCOME_META, POPULATION_LABELS, POPULATION_NOTES, PANEL_ORDER } from './data/display'
import TrajectoryChart from './components/TrajectoryChart'
import ComponentComparisons from './components/ComponentComparisons'
import StudyPopulation from './components/StudyPopulation'
import ObservedPatterns from './components/ObservedPatterns'
import SensitivityAnalyses from './components/SensitivityAnalyses'
import { curveDomain, formatValue, type CurveDomain } from './components/trajectoryGeometry'
import './components/trajectoryLayout.css'
import SummaryDownload from './components/SummaryDownload'
import OptionsPanel from './components/OptionsPanel'
import { trajectorySummarySvg } from './figures/summarySvg'

type Outcome = typeof OUTCOMES[number]
type Card = { state: 'loading' | 'ready' | 'unavailable' | 'error'; message?: string; points?: readonly TrajectoryPoint[]; endpoint?: { estimate: number | null; lower: number | null; upper: number | null } }
const ordered: readonly Outcome[] = PANEL_ORDER
const views = ['Main results', 'Component comparisons', 'Sensitivity analyses', 'Observed patterns', 'Study details'] as const

export default function App() {
  const [view, setView] = useState<typeof views[number]>(() => { const selected = new URLSearchParams(location.search).get('view'); return selected === 'components' ? 'Component comparisons' : selected === 'observed' ? 'Observed patterns' : selected === 'population' ? 'Study details' : selected === 'sensitivity' ? 'Sensitivity analyses' : 'Main results' })
  const [model, setModel] = useState<FitKey['model']>(() => new URLSearchParams(location.search).get('model') === 'BASE' ? 'BASE' : 'FULL')
  const [population, setPopulation] = useState<FitKey['population']>(() => { const value = new URLSearchParams(location.search).get('population'); return POPULATIONS.find(p => p === value) ?? 'PRIMARY' })
  const [scale, setScale] = useState<'levels' | 'changes'>(() => new URLSearchParams(location.search).get('scale') === 'levels' ? 'levels' : 'changes')
  const [windowMinutes, setWindowMinutes] = useState(() => { const value = Number(new URLSearchParams(location.search).get('minutes')); return [60, 360, 720].includes(value) ? value : 720 })
  const [publicationView, setPublicationView] = useState(0)
  const [retry, setRetry] = useState(0)
  const [releaseId, setReleaseId] = useState<string>()
  const [releaseError, setReleaseError] = useState(false)
  const [loaded, setLoaded] = useState<{ key: string; cards: Partial<Record<Outcome, Card>> }>({ key: '', cards: {} })
  const selection = `${releaseId ?? ''}/${population}/${model}/${scale}`
  const cards = useMemo(() => loaded.key === selection ? loaded.cards : {}, [loaded, selection])

  useEffect(() => {
    const controller = new AbortController()
    setReleaseId(undefined)
    setReleaseError(false)
    openReader(controller.signal)
      .then(value => { if (!controller.signal.aborted) setReleaseId(value.releaseId) })
      .catch(() => { if (!controller.signal.aborted) setReleaseError(true) })
    return () => controller.abort()
  }, [retry])

  useEffect(() => {
    if (!releaseId || view !== 'Main results') return
    const controller = new AbortController()
    setLoaded({ key: selection, cards: {} })
    const endpointKey = 'endpoints/' + model
    const endpoints = readDisplay(endpointKey, controller.signal).then(value => displayEndpoints(endpointKey, value))
    for (const outcome of ordered) {
      const store = (card: Card) => {
        if (!controller.signal.aborted) setLoaded(current => current.key === selection ? { key: selection, cards: { ...current.cards, [outcome]: card } } : current)
      }
      const curveKey = ['main', population, model, outcome, scale].join('/')
      Promise.all([readDisplay(curveKey, controller.signal).then(value => displayTrajectory(curveKey, value)), endpoints])
        .then(([points, grid]) => {
          const [estimate, lower, upper] = grid[outcome][population]
          store({ state: 'ready', points, endpoint: { estimate, lower, upper } })
        })
        .catch(error => store(isWithheld(error)
          ? { state: 'unavailable', message: 'These results are withheld.' }
          : { state: 'error', message: 'This result could not be verified or loaded.' }))
    }
    return () => controller.abort()
  }, [releaseId, population, model, scale, selection, view])

  useEffect(() => {
    const url = new URL(location.href)
    if (view === 'Main results') { url.searchParams.set('model', model); url.searchParams.set('population', population) }
    url.searchParams.set('view', view === 'Component comparisons' ? 'components' : view === 'Observed patterns' ? 'observed' : view === 'Study details' ? 'population' : view === 'Sensitivity analyses' ? 'sensitivity' : 'trajectories')
    url.searchParams.set('scale', scale); url.searchParams.set('minutes', String(windowMinutes))
    history.replaceState(null, '', url)
  }, [model, population, scale, windowMinutes, view])
  const pressureDomains = useMemo(() => {
    const domains = (['ARTm', 'ARTs', 'ARTd'] as const).map(code => [code, curveDomain((cards[code]?.points ?? []).filter(p => Math.abs(p.time) <= windowMinutes), scale === 'changes')] as const)
    const valid = domains.filter((pair): pair is readonly ['ARTm' | 'ARTs' | 'ARTd', CurveDomain] => pair[1] !== null)
    if (!valid.length) return {}
    if (scale === 'changes') {
      const shared = { min: Math.min(...valid.map(([, d]) => d.min)), max: Math.max(...valid.map(([, d]) => d.max)) }
      return Object.fromEntries(valid.map(([code]) => [code, shared])) as Partial<Record<Outcome, CurveDomain>>
    }
    const span = Math.max(...valid.map(([, d]) => d.max - d.min))
    return Object.fromEntries(valid.map(([code, d]) => [code, { min: (d.min + d.max - span) / 2, max: (d.min + d.max + span) / 2 }])) as Partial<Record<Outcome, CurveDomain>>
  }, [cards, windowMinutes, scale])

  const exportReady = Boolean(releaseId && !releaseError && ordered.every(code => cards[code]?.state === 'ready'))
  function exportTrajectories() {
    if (!releaseId || !exportReady) throw new Error('FIGURE_SCOPE_NOT_READY')
    return trajectorySummarySvg({ compact: true, releaseId, datasetKind: 'full_cohort', population, model, scale, windowMinutes,
      panels: ordered.map(outcome => {
        const card = cards[outcome]
        return { outcome, state: card?.state === 'ready' ? 'accepted' : card?.state === 'unavailable' ? 'inference_unavailable' : 'failed',
          points: card?.state === 'ready' ? card.points : undefined,
          contrast: card?.state === 'ready' ? card.endpoint : undefined,
          domain: pressureDomains[outcome], message: card?.message }
      }),
    })
  }

  const displayProps = { displayReleaseId: releaseId, release: null, assetBase: import.meta.env.BASE_URL }
  const viewIndex = views.indexOf(view)
  const navigateTo = (name: typeof views[number]) => {
    if (name === 'Main results' || name === 'Component comparisons') {
      const url = new URL(location.href)
      url.searchParams.set('model', 'FULL')
      url.searchParams.set('population', 'PRIMARY')
      for (const parameter of ['factor', 'outcome', 'comparison']) url.searchParams.delete(parameter)
      if (name === 'Component comparisons') url.searchParams.set('comparison', 'overview')
      else {
        url.searchParams.set('scale', 'changes'); url.searchParams.set('minutes', '720')
        setModel('FULL'); setPopulation('PRIMARY'); setScale('changes'); setWindowMinutes(720)
      }
      history.replaceState(null, '', url)
      setPublicationView(value => value + 1)
    }
    setView(name)
    window.scrollTo({ top: 0, behavior: 'auto' })
  }
  return <>
    <a className="skip" href="#content">Skip to results</a>
    <header className="publication-header"><div className="brand"><span className="brand-wordmark">SCANDAT</span> <span className="brand-group">Research Group</span></div><h1 className="paper-title">Physiological trajectories around red blood cell transfusion in intensive care: associations with donor and component characteristics</h1></header>
    <main id="content" className={view === 'Component comparisons' ? 'component-results' : undefined}>

      <nav aria-label="Result views">{views.map(name => <button key={name} aria-current={view === name ? 'page' : undefined} onClick={() => navigateTo(name)}>{name}</button>)}</nav>
      {view === 'Main results' ? <Fragment key={publicationView}>
        <div className="figure-heading"><div><h2>{scale === 'levels' ? 'Predicted trajectories' : 'Change from one hour before transfusion'}</h2><p>{MODEL_LABELS[model]} &middot; {POPULATION_LABELS[population]} &middot; {windowMinutes / 60} hours before and after transfusion</p></div><div className="figure-heading-actions"><span>Transfusion starts at 0 h</span><SummaryDownload ready createSvg={exportTrajectories} filename={`main-trajectories-${scale}-${population.toLowerCase()}-${model.toLowerCase()}.svg`} disabled={!exportReady}/></div></div>
        <OptionsPanel className="main-options" label="Model, population and display options" summary={`${MODEL_LABELS[model]}; ${POPULATION_LABELS[population]}; ${scale === 'changes' ? 'change from 1 h before' : 'absolute levels'}; ${windowMinutes / 60} hours before and after transfusion`}>
        <div className="controls">
          <label>Analysis population<select aria-label="Analysis population" value={population} onChange={event => setPopulation(event.target.value as FitKey['population'])}>{POPULATIONS.map(code => <option value={code} key={code}>{POPULATION_LABELS[code]}</option>)}</select></label>
          <label>Model<select aria-label="Model" value={model} onChange={event => setModel(event.target.value as FitKey['model'])}>{(['FULL', 'BASE'] as const).map(code => <option value={code} key={code}>{code === 'FULL' ? 'Full (primary)' : 'Base (comparison)'}</option>)}</select></label>
          <fieldset><legend>Display</legend><div className="segmented">{(['changes', 'levels'] as const).map(code => <button key={code} aria-pressed={scale === code} onClick={() => setScale(code)}>{code === 'levels' ? 'Absolute level' : 'Change from -1 h'}</button>)}</div></fieldset>
          <label>Time window<select aria-label="Time window" value={windowMinutes} onChange={event => setWindowMinutes(Number(event.target.value))}>{[60, 360, 720].map(value => <option key={value} value={value}>&plusmn;{value / 60} hours</option>)}</select></label>
        </div>
          {(model !== 'FULL' || population !== 'PRIMARY' || scale !== 'changes' || windowMinutes !== 720) && <button className="text-button" onClick={() => { setModel('FULL'); setPopulation('PRIMARY'); setScale('changes'); setWindowMinutes(720) }}>Reset to main analysis</button>}
        </OptionsPanel>
        {releaseError ? <div className="error" role="alert"><h3>Results could not be loaded</h3><p>A compatible, verified result release is required.</p><button onClick={() => setRetry(value => value + 1)}>Try again</button></div> : <div className="panel-grid trajectory-grid publication-figure-grid" aria-label="Seven outcomes and figure key">
          {ordered.map(code => {
            const meta = OUTCOME_META[code], card = cards[code]
            const unit = scale === 'changes' ? meta.changeUnit : meta.unit
            return <section className="trajectory-card" aria-labelledby={`title-${code}`} key={code}>
              <div className="card-title"><div><h3 id={`title-${code}`}>{meta.name}</h3><p>{unit}</p></div><span className="outcome-code">{meta.shortName}</span></div>
              {card?.state === 'ready' && card.points && releaseId ? <><TrajectoryChart key={`${selection}/${code}`} points={card.points} title={meta.name} unit={unit} windowMinutes={windowMinutes} color={meta.color} domain={pressureDomains[code]} change={scale === 'changes'} downloadContext={{ releaseId, datasetKind: 'full_cohort', population, model, outcome: code, scale }} footer={<div className="endpoint-summary"><div className="endpoint"><span>1 h after versus 1 h before</span><strong>{formatValue(card.endpoint?.estimate ?? null)} <small>{meta.changeUnit}</small></strong></div><div className="endpoint-ci">{card.endpoint?.lower !== null && card.endpoint?.lower !== undefined && card.endpoint.upper !== null ? `95% CI ${formatValue(card.endpoint.lower)} to ${formatValue(card.endpoint.upper)}` : 'Confidence interval unavailable'}</div></div>}/></> : <div className="card-empty" role="status">{card?.message ?? 'Loading trajectory...'}</div>}
            </section>
          })}
          <section className="figure-key" aria-labelledby="trajectory-key-title">
            <h3 id="trajectory-key-title">How to read the figure</h3>
            <ul className="trajectory-legend" aria-label="Figure symbols">
              <li><i className="legend-line" aria-hidden="true"/>{scale === 'levels' ? 'Adjusted predicted mean' : 'Adjusted predicted change'}</li>
              <li><i className="legend-band" aria-hidden="true"/>Pointwise 95% CI</li>
              <li><i className="legend-transfusion" aria-hidden="true"/>Transfusion start (0 h)</li>
              <li><i className="legend-points" aria-hidden="true"/>Values at −1 and +1 h</li>
            </ul>
            <p>The curves span {windowMinutes / 60} hours before and after transfusion. {scale === 'levels' ? 'Predictions are for the model’s reference profile.' : 'Change is relative to the predicted value one hour before transfusion.'}</p>
            <p>Below each panel: the predicted value one hour after minus one hour before transfusion, with its 95% CI.</p>
            <p>Oxygen changes are absolute percentage-point differences, not relative percentages.</p>
          </section>
        </div>}
        <details className="method-note"><summary>Population, adjustment and interpretation</summary><p>{POPULATION_NOTES[population]}</p>{model === 'FULL' && <p>{FULL_MODEL_NOTE}</p>}<p>{REFERENCE_PROFILE_NOTE}</p><p>Shading shows pointwise 95% confidence intervals for {scale === 'levels' ? 'the predicted mean' : 'the predicted change'}. These describe uncertainty at each time point, not for the whole curve or an individual patient’s response.</p><p>Values are displayed in the recorded clinical units without rescaling. Changes in inspired oxygen and oxygen saturation are expressed in percentage points. Inspect values by hovering over the curve or using the arrow keys after selecting it.</p></details>
      </Fragment> : view === 'Component comparisons' ? <ComponentComparisons {...displayProps} key={publicationView} releaseError={releaseError}/> : view === 'Sensitivity analyses' ? <SensitivityAnalyses {...displayProps} releaseError={releaseError}/> : view === 'Study details' ? <StudyPopulation {...displayProps} supplement={null} supplementState={releaseError ? 'error' : 'loading'}/> : <ObservedPatterns displayReleaseId={releaseId} releaseError={releaseError}/>}
      <nav className="section-navigation" aria-label="Continue through results">
        {viewIndex > 0 ? <button onClick={() => navigateTo(views[viewIndex - 1]!)}>← {views[viewIndex - 1]}</button> : <span/>}
        {viewIndex < views.length - 1 && <button onClick={() => navigateTo(views[viewIndex + 1]!)}>Next: {views[viewIndex + 1]} →</button>}
      </nav>
    </main>
    <footer><div className="brand"><span className="brand-wordmark">SCANDAT</span> <span className="brand-group">Research Group</span></div></footer>
  </>
}
