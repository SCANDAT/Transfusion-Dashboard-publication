import { useEffect, useState } from 'react'
import { POPULATIONS, type FitKey, type ValidatedRelease } from '../data/release'
import { loadTable } from '../data/loader'
import { hasUsableBand, numericCell, tableRows, textCell } from '../data/tables'
import { OUTCOME_META, POPULATION_LABELS, FULL_MODEL_NOTE, PANEL_ORDER, MODEL_LABELS } from '../data/display'
import { isWithheld, readDisplay } from '../data/reader'
import { displayEndpoints } from '../data/mainDisplay'
import ForestPlot, { type ForestRow } from './ForestPlot'
import SummaryDownload from './SummaryDownload'
import OptionsPanel from './OptionsPanel'
import { sensitivitySummarySvg } from '../figures/summarySvg'
import './sensitivityLayout.css'

type Props = { release: ValidatedRelease | null; assetBase: string; releaseError: boolean; displayReleaseId?: string }
export default function SensitivityAnalyses({ release, assetBase, releaseError, displayReleaseId }: Props) {
  const [model, setModel] = useState<FitKey['model']>('FULL')
  const releaseId = displayReleaseId ?? release?.manifest.releaseId
  const selection = `${releaseId}/${model}`
  const [loaded, setLoaded] = useState<{ selection: string; rows: Record<string, ForestRow> }>({ selection: '', rows: {} })
  const rows = loaded.selection === selection ? loaded.rows : {}
  useEffect(() => {
    if (!displayReleaseId && !release) return
    const controller = new AbortController()
    setLoaded({ selection, rows: {} })
    if (displayReleaseId) {
      const key = 'endpoints/' + model
      const storeGrid = (grid?: ReturnType<typeof displayEndpoints>, unavailableLabel?: string) => {
        if (controller.signal.aborted) return
        const complete: Record<string, ForestRow> = {}
        for (const outcome of PANEL_ORDER) for (const population of POPULATIONS) {
          const id = outcome + '/' + population
          const label = POPULATION_LABELS[population]
          const values = grid?.[outcome][population]
          complete[id] = values ? { id, label, estimate: values[0], lower: values[1], upper: values[2] }
            : { id, label, estimate: null, lower: null, upper: null, unavailableLabel }
        }
        setLoaded({ selection, rows: complete })
      }
      readDisplay(key, controller.signal).then(value => storeGrid(displayEndpoints(key, value)))
        .catch(error => storeGrid(undefined, isWithheld(error) ? 'Results withheld' : 'Result could not be loaded'))
      return () => controller.abort()
    }
    if (!release) return
    for (const outcome of PANEL_ORDER) for (const population of POPULATIONS) {
      const id = `${outcome}/${population}`, label = POPULATION_LABELS[population]
      const store = (row: ForestRow) => { if (!controller.signal.aborted) setLoaded(current => current.selection === selection ? { selection, rows: { ...current.rows, [id]: row } } : current) }
      const empty = (unavailableLabel: string) => ({ id, label, estimate: null, lower: null, upper: null, unavailableLabel })
      const key: FitKey = { outcome, population, model, factor: 'MAIN' }
      const job = release.manifest.jobs.find(item => item.key.outcome === outcome && item.key.population === population && item.key.model === model && item.key.factor === 'MAIN')
      if (!job || job.state !== 'accepted') { store(empty(!job || job.state === 'pending' ? 'Not yet available' : job.state === 'failed' ? 'Result unavailable' : 'Inference unavailable')); continue }
      loadTable(release, key, 'within', assetBase, controller.signal).then(table => {
        const values = tableRows(table)
        if (values.length !== 1 || numericCell(values[0]!, 'BaselineMinute') !== -60 || numericCell(values[0]!, 'EndpointMinute') !== 60) throw new Error('SENSITIVITY_ENDPOINT_IDENTITY')
        const row = values[0]!
        const point = { category: 1, time: 60, estimate: numericCell(row, 'Estimate'), lower: numericCell(row, 'Lower'), upper: numericCell(row, 'Upper'), numericStatus: textCell(row, 'NumericStatus'), contrastStatus: numericCell(row, 'ContrastStatus') }
        if (!hasUsableBand(point) || point.numericStatus !== 'COMPUTED' || point.contrastStatus !== 0) throw new Error('SENSITIVITY_INFERENCE_UNAVAILABLE')
        store({ id, label, estimate: point.estimate, lower: point.lower, upper: point.upper })
      }).catch(() => store(empty('Result could not be loaded')))
    }
    return () => controller.abort()
  }, [release, assetBase, model, selection, displayReleaseId])
  const exportReady = Boolean((displayReleaseId || release?.manifest.datasetKind === 'full_cohort') && !releaseError && PANEL_ORDER.every(outcome => POPULATIONS.every(population => {
    const row = rows[outcome + '/' + population]
    return row && (!displayReleaseId || row.estimate !== null)
  })))
  function exportSensitivities() {
    if (!releaseId || !exportReady) throw new Error('FIGURE_SCOPE_NOT_READY')
    return sensitivitySummarySvg({ ...(displayReleaseId ? { compact: true as const } : {}), releaseId, datasetKind: 'full_cohort', model,
      panels: PANEL_ORDER.map(outcome => ({ outcome, rows: POPULATIONS.map(population => {
        const row = rows[`${outcome}/${population}`]!
        return { population, estimate: row.estimate, lower: row.lower, upper: row.upper, unavailableLabel: row.unavailableLabel }
      }) })),
    })
  }
  return <section className="sensitivity-view" aria-labelledby="sensitivity-heading">
    <div className="view-heading"><div><h2 id="sensitivity-heading">Sensitivity analyses</h2><p>Change from −1 to +1 hour in each analysis population.</p></div>
      <div className="figure-heading-actions"><OptionsPanel className="sensitivity-options" label="Sensitivity model options" summary={MODEL_LABELS[model]}><label className="compact-control">Model<select aria-label="Model" value={model} onChange={event => setModel(event.target.value as FitKey['model'])}><option value="FULL">Full (primary)</option><option value="BASE">Base (comparison)</option></select></label></OptionsPanel><SummaryDownload ready createSvg={exportSensitivities} filename={`sensitivity-comparisons-${model.toLowerCase()}.svg`} disabled={!exportReady}/></div>
    </div>
    {releaseError ? <div className="error" role="status">Results could not be loaded.</div> : <div className="panel-grid sensitivity-grid publication-figure-grid" aria-label="Seven sensitivity outcomes and figure key">{PANEL_ORDER.map(outcome => {
      const meta = OUTCOME_META[outcome]
      return <section className="trajectory-card" key={outcome} aria-labelledby={`sensitivity-${outcome}`}>
        <div className="card-title"><div><h3 id={`sensitivity-${outcome}`}>{meta.name}</h3><p>{meta.changeUnit}</p></div></div>
        <ForestPlot alignColumns showLegend={false} context={`${MODEL_LABELS[model]}; predicted change from 1 h before to 1 h after transfusion${outcome === 'FIO2' || outcome === 'SPO2' ? '; absolute percentage-point difference, not a relative percentage' : ''}`} title={`${meta.name}: changes by population`} rowHeading="Population" unit={meta.changeUnit} color={meta.color} zeroLabel="no change" rows={POPULATIONS.map(population => rows[`${outcome}/${population}`] ?? { id: population, label: POPULATION_LABELS[population], estimate: null, lower: null, upper: null, unavailableLabel: 'Loading…' })}/>
      </section>
    })}<section className="figure-key"><h3>Populations compared</h3><ul className="trajectory-legend" aria-label="Sensitivity figure symbols"><li><i className="legend-estimate" aria-hidden="true"/>Predicted change, −1 to +1 h</li><li><i className="legend-interval" aria-hidden="true"/>Pointwise 95% CI</li><li><i className="legend-transfusion" aria-hidden="true"/>Zero: no change</li></ul><p><strong>Main analysis:</strong> all eligible transfusion events.</p><p><strong>First event:</strong> one eligible event per patient.</p><p><strong>No further unit:</strong> no additional recorded RBC unit within 12 hours, with the required recorded follow-up coverage.</p><p>Each row has its own fitted model and reference profile. These intervals do not test differences between populations.</p><p>Oxygen changes are absolute percentage-point differences, not relative percentages.</p></section></div>}
    <details className="method-note"><summary>Populations and interpretation</summary>
      <p>The first-event analysis includes each person's earliest eligible event. The other sensitivity excludes events followed by another recorded RBC unit within 12 hours, with the required recorded follow-up coverage.</p>
      <p>Each row comes from its own fitted model and reference profile. These intervals describe change within each population; they do not test differences between overlapping populations.</p>
      {model === 'FULL' && <p>{FULL_MODEL_NOTE}</p>}
    </details>
  </section>
}
