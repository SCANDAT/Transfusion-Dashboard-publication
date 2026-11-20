import { hasUsableBand, type TrajectoryPoint } from '../data/tables'
export interface CurveDomain { min: number; max: number }
export function curveDomain(points: readonly TrajectoryPoint[], zero: boolean): CurveDomain | null {
  const values = points.flatMap(p => [p.estimate, ...(hasUsableBand(p) ? [p.lower, p.upper] : [])]).filter((v): v is number => v !== null && Number.isFinite(v))
  if (!values.length) return null
  if (zero) values.push(0)
  const min = Math.min(...values), max = Math.max(...values)
  const pad = Math.max((max - min) * 0.12, Math.abs(max) * 0.0001, 0.001)
  return { min: min - pad, max: max + pad }
}
export function formatValue(value: number | null, digits = 2): string {
  if (value === null) return 'Unavailable'
  const formatted = value.toLocaleString('en-GB', { maximumFractionDigits: digits, minimumFractionDigits: 0 })
  return formatted === '-0' ? '0' : formatted
}
