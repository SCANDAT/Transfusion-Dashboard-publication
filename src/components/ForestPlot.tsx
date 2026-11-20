import { formatProbability, type DisplayProbability } from '../data/componentDisplay'
import { useRef, useState, type ReactNode } from 'react'
import ChartDialog from './ChartDialog'
import { formatValue } from './trajectoryGeometry'

export interface ForestRow {
  id: string; label: string; estimate: number | null; lower: number | null; upper: number | null
  unavailableLabel?: string; holmP?: DisplayProbability | null; comparison?: { first: string; second: string }
}
interface Props { rows: readonly ForestRow[]; title: string; unit: string; color: string; zeroLabel: string; showHolm?: boolean; rowHeading?: string; showLegend?: boolean; reference?: { label: string }; context?: ReactNode; expandable?: boolean; axisBound?: number; stackComparisonLabels?: boolean; alignColumns?: boolean }

export default function ForestPlot({ rows, title, unit, color, zeroLabel, showHolm = false, rowHeading = 'Category', showLegend = true, reference, context, expandable = true, axisBound, stackComparisonLabels = false, alignColumns = false }: Props) {
  const [expanded, setExpanded] = useState(false)
  const enlargeButton = useRef<HTMLButtonElement>(null)
  const values = rows.flatMap(row => [row.estimate, row.lower, row.upper]).filter((value): value is number => value !== null && Number.isFinite(value))
  const extent = Math.max(...values.map(Math.abs), 0.01) * 1.12
  const step = 10 ** Math.floor(Math.log10(extent))
  const automaticBound = Math.ceil(extent / step) * step
  const bound = axisBound !== undefined && Number.isFinite(axisBound) && axisBound > 0 && values.every(value => Math.abs(value) <= axisBound) ? axisBound : automaticBound
  const x = (value: number) => 12 + (value + bound) / (2 * bound) * 276
  const canExpand = expandable && Boolean(values.length || reference)
  return <div className={`estimate-forest${showHolm ? ' has-holm' : ''}${stackComparisonLabels ? ' stacked-comparisons' : ''}${alignColumns ? ' aligned-columns' : ''}${canExpand ? ' chart-expandable' : ''}`} role="group" aria-label={title}
    onClick={event => { if (canExpand && !expanded && event.target instanceof Element && event.target.closest('svg')) { enlargeButton.current?.focus(); setExpanded(true) } }}>
    {canExpand && <button ref={enlargeButton} className="chart-enlarge" type="button" aria-label={`Enlarge chart: ${title}`} onClick={event => { event.currentTarget.focus(); setExpanded(true) }}>Enlarge chart</button>}
    <div className="estimate-forest-heading"><span>{rowHeading}</span><span>{unit}</span><span>Estimate <span className="estimate-heading-ci">(95% CI)</span></span>{showHolm && <span>Holm p</span>}</div>
    {reference && <div className="estimate-forest-row estimate-reference-row">
      <span className="estimate-label">{reference.label} (reference)</span>
      <svg viewBox="0 0 300 36" preserveAspectRatio="none" className="estimate-interval" role="img" aria-label={`${reference.label}: reference; zero by definition`}>
        <line x1={x(0)} x2={x(0)} y1={0} y2={36} className="event-line" vectorEffect="non-scaling-stroke"/>
        <g className="estimate-reference-marker">
          <path d={`M${x(0)},18h0.001`} stroke="#78847f" strokeWidth={7} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
          <path d={`M${x(0)},18h0.001`} stroke="white" strokeWidth={4} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
        </g>
      </svg>
      <span className="estimate-number"><small>Reference; zero by definition</small></span>
      {showHolm && <span aria-hidden="true"/>}
    </div>}
    {rows.map(row => {
      const available = row.estimate !== null && row.lower !== null && row.upper !== null
      const ci = available ? `${formatValue(row.lower)} to ${formatValue(row.upper)}` : row.unavailableLabel ?? 'Unavailable'
      return <div className="estimate-forest-row" key={row.id}>
        <span className={`estimate-label${stackComparisonLabels && row.comparison ? ' estimate-label-stacked' : ''}`} aria-label={row.label}>{stackComparisonLabels && row.comparison ? <><span className="estimate-comparison-first">{row.comparison.first}</span>{' '}<span className="estimate-comparison-vs">vs</span>{' '}<span className="estimate-comparison-second">{row.comparison.second}</span></> : row.label}</span>
        <svg viewBox="0 0 300 36" preserveAspectRatio="none" className="estimate-interval" role="img" aria-label={`${row.label}: ${available ? `${formatValue(row.estimate)}; 95% CI ${ci} ${unit}` : ci}`}>
          {values.length > 0 && <line x1={x(0)} x2={x(0)} y1={0} y2={36} className="event-line" vectorEffect="non-scaling-stroke"/>}
          {available && <g data-estimate={row.estimate} data-lower={row.lower} data-upper={row.upper}>
            <line x1={x(row.lower!)} x2={x(row.upper!)} y1={18} y2={18} stroke={color} strokeWidth={2} vectorEffect="non-scaling-stroke"/>
            <line x1={x(row.lower!)} x2={x(row.lower!)} y1={13} y2={23} stroke={color} vectorEffect="non-scaling-stroke"/>
            <line x1={x(row.upper!)} x2={x(row.upper!)} y1={13} y2={23} stroke={color} vectorEffect="non-scaling-stroke"/>
            <path d={`M${x(row.estimate!)},18h0.001`} stroke={color} strokeWidth={7} strokeLinecap="round" vectorEffect="non-scaling-stroke"/>
          </g>}
        </svg>
        <span className="estimate-number">{available ? <><strong>{formatValue(row.estimate)}</strong><small>{ci}</small></> : <small>{ci}</small>}</span>
        {showHolm && <span className="estimate-p">{formatProbability(row.holmP)}</span>}
      </div>
    })}
    {values.length > 0 && <div className="estimate-forest-axis" aria-hidden="true"><span/><div className="forest-ticks"><span>{formatValue(-bound)}</span><span>0</span><span>{formatValue(bound)}</span></div><span/>{showHolm && <span/>}</div>}
    {(showLegend || !values.length) && <p className="forest-zero-note">{values.length ? <>Zero: {zeroLabel}. Dots show estimates; bars show pointwise 95% confidence intervals.{reference && ' The hollow grey dot is the reference: zero by definition, with no confidence interval or p value.'}</> : 'No estimates are available for these comparisons.'}</p>}
    {canExpand && <ChartDialog open={expanded} title={title} context={<>{context}<p>{unit} · {showHolm ? 'Holm-adjusted p values; pointwise confidence intervals' : 'Pointwise 95% confidence intervals'}</p></>} onClose={() => setExpanded(false)}>
      <ForestPlot rows={rows} title={title} unit={unit} color={color} zeroLabel={zeroLabel} showHolm={showHolm} rowHeading={rowHeading} showLegend reference={reference} context={context} expandable={false} axisBound={axisBound} stackComparisonLabels={stackComparisonLabels} alignColumns={alignColumns}/>
    </ChartDialog>}
  </div>
}
