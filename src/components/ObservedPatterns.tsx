import { useEffect, useId, useMemo, useState } from 'react'
import { OUTCOMES } from '../data/release'
import { OUTCOME_META } from '../data/display'
import { readDisplay, isWithheld } from '../data/reader'
import { OBSERVED_SPANS, validateObservedDisplay, type ObservedCurve } from '../data/observedDisplay'
import { loessStatusLabel, type LoessOutcome, type LoessScale } from '../data/loess'
import LoessChart from './LoessChart'
import OptionsPanel from './OptionsPanel'
import './observedPatterns.css'

interface Props { releaseError: boolean; displayReleaseId?: string }
export default function ObservedPatterns({ releaseError, displayReleaseId }: Props) {
  const spanId = useId()
  const [outcome, setOutcome] = useState<LoessOutcome>('ARTm')
  const [scale, setScale] = useState<LoessScale>('native')
  const [spanPercent, setSpanPercent] = useState(30)
  const [windowMinutes, setWindowMinutes] = useState(720)
  const [retry, setRetry] = useState(0)
  const [result, setResult] = useState<{ key: string; state: 'loading' | 'ready' | 'error' | 'withheld'; value?: ReadonlyMap<number, ObservedCurve> }>({ key: '', state: 'loading' })
  const spans = OBSERVED_SPANS
  const spanIndex = spans.indexOf(spanPercent)
  const selection = JSON.stringify([displayReleaseId, outcome, scale])
  const curves = result.key === selection && result.state === 'ready' ? result.value : undefined
  const series = curves?.get(spanPercent)
  const domain = useMemo(() => {
    if (!curves) return undefined
    let min = Infinity, max = -Infinity
    for (const curve of curves.values()) for (const row of curve.rows) if (row[1] !== null) { min = Math.min(min, row[1]); max = Math.max(max, row[1]) }
    if (!Number.isFinite(min) || !Number.isFinite(max)) return undefined
    const padding = Math.max((max - min) * .12, Math.max(Math.abs(min), Math.abs(max), 1) * .001)
    return { min: min - padding, max: max + padding }
  }, [curves])
  const points = useMemo(() => series ? series.rows.map(([time, estimate, pointStatus, supportStatus]) => ({ time, estimate, pointStatus, supportStatus })) : [], [series])
  const meta = OUTCOME_META[outcome]
  const unit = scale === 'native' ? meta.unit : 'SD units'
  useEffect(() => {
    if (!displayReleaseId) return
    const controller = new AbortController()
    const key = `observed/${outcome}/${scale}`
    setResult({ key: selection, state: 'loading' })
    readDisplay(key, controller.signal).then(raw => validateObservedDisplay(key, raw)).then(value => {
      if (!controller.signal.aborted) setResult({ key: selection, state: 'ready', value })
    }).catch((reason: unknown) => {
      if (!controller.signal.aborted) setResult({ key: selection, state: isWithheld(reason) ? 'withheld' : 'error' })
    })
    return () => controller.abort()
  }, [displayReleaseId, outcome, scale, selection, retry])
  const error = releaseError || result.key === selection && result.state === 'error'
  const scaleToggle = <div className="segmented loess-scale-toggle" role="group" aria-label="Scale">
            <button type="button" aria-pressed={scale === 'native'} onClick={() => setScale('native')}>Recorded units</button>
            <button type="button" aria-pressed={scale === 'standardized'} onClick={() => setScale('standardized')}>Standardised (SD)</button>
          </div>
  const withheld = result.key === selection && result.state === 'withheld'
  return <section className="observed-patterns" aria-labelledby="observed-title">
    <div className="view-heading"><div><h2 id="observed-title">Observed time patterns</h2><p>Unadjusted LOESS curves &middot; Main population</p></div></div>
    <div className="controls loess-controls primary-controls">
      <label>Vital parameter<select aria-label="Vital parameter" value={outcome} onChange={event => setOutcome(event.target.value as LoessOutcome)}>{OUTCOMES.map(code => <option key={code} value={code}>{OUTCOME_META[code].name}</option>)}</select></label>
      <label>Time window<select aria-label="Time window" value={windowMinutes} onChange={event => setWindowMinutes(Number(event.target.value))}>{[60, 360, 720].map(value => <option key={value} value={value}>&plusmn;{value / 60} hours</option>)}</select></label>
    </div>
    <OptionsPanel className="loess-smoothing-options" label="Smoothing options" summary={`Smoothing span ${(spanPercent / 100).toFixed(2)}`}><div className="controls loess-smoothing-controls">
      <label className="loess-span-control" htmlFor={spanId}>
        <span className="loess-span-heading">Smoothing span<output htmlFor={spanId}>{(spanPercent / 100).toFixed(2)}</output></span>
        <input id={spanId} type="range" aria-label="Smoothing span" aria-valuetext={(spanPercent / 100).toFixed(2)} aria-describedby={`${spanId}-help`}
          min={0} max={Math.max(0, spans.length - 1)} step={1} value={Math.max(0, spanIndex)} disabled={!curves || spans.length < 2 || spanIndex < 0}
          onChange={event => { const value = spans[Number(event.target.value)]; if (value !== undefined) setSpanPercent(value) }}/>
        <span className="loess-span-limits" aria-hidden="true"><span>{spans.length ? (spans[0]! / 100).toFixed(2) : '\u2014'}</span><span>{spans.length ? (spans[spans.length - 1]! / 100).toFixed(2) : '\u2014'}</span></span>
      </label>
    </div></OptionsPanel><p className="report-note" id={`${spanId}-help`}>Larger spans give smoother curves. The slider selects fitted curves; changing the time window only crops them.</p>
    <p className="report-note">These curves describe the observed time pattern. They do not include covariate adjustment or confidence intervals.</p>
    {(withheld || error) && <div className="loess-heading-actions">{scaleToggle}</div>}
    {error ? <div className="error" role="alert"><h3>Descriptive results could not be loaded</h3><p>The selected curve could not be verified against this release.</p><button onClick={() => setRetry(value => value + 1)}>Try again</button></div> : withheld ? <div className="report-empty" role="status">The selected descriptive curves are withheld from this release.</div> : <section className="trajectory-card loess-card" aria-labelledby="loess-outcome-title">
      <div className="card-title"><div><h3 id="loess-outcome-title">{meta.name}</h3><p>{scale === 'native' ? meta.unit : 'Standard deviations from the outcome mean'}</p></div>
        <div className="loess-heading-actions">
          {scaleToggle}
          <span className="outcome-code">Span {(spanPercent / 100).toFixed(2)}</span>
        </div>
      </div>
      {series ? <LoessChart points={points} title={meta.name} unit={unit} color={meta.color} windowMinutes={windowMinutes} domain={domain} context={`Unadjusted LOESS; main population; ${scale === 'native' ? 'recorded clinical scale' : 'standardized scale'}; span ${(spanPercent / 100).toFixed(2)}; ${windowMinutes / 60} hours before and after transfusion`}/> : <div className="loess-loading-chart" aria-busy="true"><div className="loess-loading-frame" role="status">Loading fitted curves...</div></div>}
      <div className="loess-support" role="status">{series ? loessStatusLabel(series.fitStatus) : '\u00a0'}</div>
      
    </section>}
    <details className="method-note"><summary>Smoothing, scales and available values</summary>
      <p>These descriptive curves use eligible measurements in the primary population, independently of the complete-case samples used for the base and full models. They are not adjusted for patient or treatment characteristics.</p>
      <p>Measurements recorded at the same time relative to transfusion were averaged. LOESS was fitted to a subset of these time points, giving each retained time point equal weight. Fitted values were joined by straight lines on a one-minute grid, without extrapolation or joining gaps. The time-window control changes the view, not the fitted curve.</p>
      <p>The standardized scale shows standard deviations from each outcome&rsquo;s mean, calculated from eligible measurements before restriction to the &plusmn;12-hour interval. The recorded scale shows the same fitted curve in clinical units.</p>
      <p>There are no confidence intervals for these descriptive curves. Model-based uncertainty and the comparison between one hour before and after transfusion are provided in the other result views.</p>
    </details>
  </section>
}
