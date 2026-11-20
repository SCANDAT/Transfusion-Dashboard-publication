import { useId, useMemo, useState, type ReactNode } from 'react'
import ChartDialog from './ChartDialog'
import { loessSegments, loessStatusLabel, type LoessPoint } from '../data/loess'
import { formatValue } from './trajectoryGeometry'

interface Props { points: readonly LoessPoint[]; title: string; unit: string; color: string; windowMinutes: number; domain?: { min: number; max: number }; context?: ReactNode; expandable?: boolean }
export default function LoessChart({ points, title, unit, color, windowMinutes, domain, context, expandable = true }: Props) {
  const id = useId()
  const [expanded, setExpanded] = useState(false)
  const [selectedTime, setSelectedTime] = useState<number | null>(null)
  const [keyboard, setKeyboard] = useState(false)
  const visible = useMemo(() => points.filter(point => Math.abs(point.time) <= windowMinutes), [points, windowMinutes])
  const bounds = useMemo(() => {
    if (domain) return domain
    const values = visible.flatMap(point => point.estimate === null ? [] : [point.estimate])
    if (!values.length) return null
    const min = Math.min(...values), max = Math.max(...values), padding = Math.max((max - min) * .12, Math.max(Math.abs(min), Math.abs(max), 1) * .001)
    return { min: min - padding, max: max + padding }
  }, [visible, domain])
  const selected = visible.find(point => point.time === selectedTime)
  const W = 760, H = 310, L = 66, R = 20, T = 22, B = 42
  const x = (time: number) => L + (time + windowMinutes) / (windowMinutes * 2) * (W - L - R)
  const y = (value: number) => bounds ? T + (bounds.max - value) / (bounds.max - bounds.min) * (H - T - B) : T
  const digits = bounds ? Math.max(0, Math.min(4, 1 - Math.floor(Math.log10(bounds.max - bounds.min)))) : 1
  return <div className={`chart-wrap loess-chart${expandable && bounds ? ' chart-expandable' : ''}`}>
    {expandable && bounds && <button className="chart-enlarge" type="button" aria-label={`Enlarge chart: ${title}`} onClick={event => { event.currentTarget.focus(); setExpanded(true) }}>Enlarge chart</button>}
    {bounds ? <svg viewBox={`0 0 ${W} ${H}`} role="img" tabIndex={0} aria-labelledby={`${id}-title`} aria-describedby={`${id}-desc ${id}-readout`}
      onClick={expandable ? event => { event.currentTarget.focus(); setExpanded(true) } : undefined}
      onFocus={() => { setKeyboard(true); setSelectedTime(0) }} onBlur={() => { setKeyboard(false); setSelectedTime(null) }}
      onKeyDown={event => {
        if (event.key === 'Enter' && expandable) { event.preventDefault(); setExpanded(true); return }
        if (!['ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'].includes(event.key)) return
        event.preventDefault(); setKeyboard(true)
        const time = selected?.time ?? 0
        setSelectedTime(event.key === 'Home' ? -windowMinutes : event.key === 'End' ? windowMinutes : Math.max(-windowMinutes, Math.min(windowMinutes, time + (event.key === 'PageUp' ? 60 : event.key === 'PageDown' ? -60 : event.key === 'ArrowRight' ? 1 : -1))))
      }} onPointerLeave={() => { if (!keyboard) setSelectedTime(null) }} onPointerMove={event => {
        setKeyboard(false)
        const rect = event.currentTarget.getBoundingClientRect()
        if (rect.width > 0) setSelectedTime(Math.max(-windowMinutes, Math.min(windowMinutes, Math.round((((event.clientX - rect.left) / rect.width * W - L) / (W - L - R) * 2 - 1) * windowMinutes))))
      }}>
      <title id={`${id}-title`}>{title}: descriptive fitted curve</title>
      <desc id={`${id}-desc`}>LOESS curve in {unit}. The dashed line marks transfusion start. No confidence interval or source measurements are shown. Gaps preserve unavailable fitted values. Arrow keys move one minute, Page Up and Page Down one hour, and Home or End to the window limits.</desc>
      {[0, 1, 2, 3, 4].map(i => { const value = bounds.min + (bounds.max - bounds.min) * i / 4; return <g key={i}><line x1={L} x2={W - R} y1={y(value)} y2={y(value)} className="grid-line"/><text x={L - 10} y={y(value) + 4} textAnchor="end" className="axis-text">{formatValue(value, digits)}</text></g> })}
      <line x1={x(0)} x2={x(0)} y1={T} y2={H - B} className="event-line"/>
      {loessSegments(visible).map((part, index) => <path key={index} d={`M${part.map(point => `${x(point.time)},${y(point.estimate!)}`).join(' L')}`} fill="none" stroke={color} strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round"/>)}
      {[-windowMinutes, -windowMinutes / 2, 0, windowMinutes / 2, windowMinutes].map(time => <text key={time} x={x(time)} y={H - B + 20} textAnchor="middle" className="axis-text">{time > 0 ? '+' : ''}{formatValue(time / 60, 1)}</text>)}
      <text x={(L + W - R) / 2} y={H - 2} textAnchor="middle" className="axis-label">Hours from transfusion start</text>
      {selected && <line x1={x(selected.time)} x2={x(selected.time)} y1={T} y2={H - B} className="hover-line"/>}
    </svg> : <div className="chart-unavailable" role="status">No fitted values are available in this time window.</div>}
    <div className="chart-readout" id={`${id}-readout`} aria-live={keyboard ? 'polite' : 'off'}>{selected ? <>{formatValue(selected.time / 60, 2)} h: {selected.estimate !== null && <><strong>{formatValue(selected.estimate, 3)}</strong> {unit} &middot; </>}{loessStatusLabel(selected.pointStatus)}{selected.pointStatus !== selected.supportStatus && `; ${loessStatusLabel(selected.supportStatus)}`}</> : 'Hover or focus the chart and use arrow keys to inspect fitted values and support'}</div>
    {expandable && bounds && <ChartDialog open={expanded} title={title} context={<>{context}<p>Descriptive LOESS curve · {unit} · ±{windowMinutes / 60} hours</p><p>No confidence interval or source measurements are shown.</p></>} onClose={() => setExpanded(false)}>
      <LoessChart points={points} title={title} unit={unit} color={color} windowMinutes={windowMinutes} domain={domain} context={context} expandable={false}/>
    </ChartDialog>}
  </div>
}
