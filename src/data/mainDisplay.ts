import { MODELS, OUTCOMES, POPULATIONS, type FitKey } from './release'
import type { TrajectoryPoint } from './tables'

type Interval = readonly [number, number, number]
type EndpointGrid = Record<FitKey['outcome'], Record<FitKey['population'], Interval>>

function check(ok: unknown): asserts ok {
  if (!ok) throw new Error('INVALID_MAIN_DISPLAY')
}

function exact(value: unknown, fields: readonly string[]): asserts value is Record<string, unknown> {
  check(typeof value === 'object' && value !== null && !Array.isArray(value))
  check(Object.keys(value).length === fields.length && fields.every(field => Object.prototype.hasOwnProperty.call(value, field)))
}

function interval(value: unknown): asserts value is Interval {
  check(Array.isArray(value) && value.length === 3)
  for (const number of value) check(typeof number === 'number' && Number.isFinite(number) && !Object.is(number, -0))
  check(value[1] <= value[0] && value[0] <= value[2])
}

function endpoints(key: string, value: unknown): EndpointGrid {
  const [group, model, ...rest] = key.split('/')
  check(group === 'endpoints' && MODELS.some(code => code === model) && rest.length === 0)
  exact(value, ['key', 'panels'])
  check(value.key === key)
  exact(value.panels, OUTCOMES)
  for (const outcome of OUTCOMES) {
    const rows = value.panels[outcome]
    exact(rows, POPULATIONS)
    for (const population of POPULATIONS) interval(rows[population])
  }
  return value.panels as EndpointGrid
}

function trajectory(key: string, value: unknown): readonly Interval[] {
  const [group, population, model, outcome, scale, ...rest] = key.split('/')
  check(group === 'main' && POPULATIONS.some(code => code === population) && MODELS.some(code => code === model)
    && OUTCOMES.some(code => code === outcome) && (scale === 'levels' || scale === 'changes') && rest.length === 0)
  exact(value, ['key', 'points'])
  check(value.key === key && Array.isArray(value.points) && value.points.length === 1441)
  for (const point of value.points) interval(point)
  if (scale === 'changes') check(value.points[660].every((number: unknown) => number === 0))
  return value.points as Interval[]
}

export function validateMainDisplay(key: string, value: unknown): void {
  if (key.startsWith('main/')) trajectory(key, value)
  else endpoints(key, value)
}

export function displayEndpoints(key: string, value: unknown): EndpointGrid {
  return endpoints(key, value)
}

export function displayTrajectory(key: string, value: unknown): readonly TrajectoryPoint[] {
  const change = key.endsWith('/changes')
  return trajectory(key, value).map(([estimate, lower, upper], index) => {
    const time = index - 720
    const baseline = change && time === -60
    return { category: 1, time, estimate, lower, upper, numericStatus: baseline ? 'BASELINE_ZERO' : 'COMPUTED', contrastStatus: baseline ? 2 : 0 }
  })
}
