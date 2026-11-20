import type { CategoryComparison, JointComparison, JointStatus, PairComparison } from './comparisons'
import type { FitKey } from './release'

export type ComponentFactor = Exclude<FitKey['factor'], 'MAIN'>
export const componentCategories: Record<ComponentFactor, readonly string[]> = {
  DonorHb_Cat: ['1','2','3','4','5'], Storage_Cat: ['1','2','3','4','5'],
  wdy_donation: ['2','3','4','5','6'], DonorSex: ['1','2'], DonorParity_Female: ['0','1'],
}
const populations = ['PRIMARY','FIRST_EVENT','NO_FOLLOWING_UNIT_12H']
const outcomes = ['ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE']
const jointStatuses: readonly JointStatus[] = ['COMPUTED','LOW_EFFECTIVE_DF','INSUFFICIENT_EFFECTIVE_DF',
  'NOT_APPLICABLE_SINGLE_CATEGORY','MOMENT_PRECISION_UNRESOLVED','DF2_SIGN_UNRESOLVED']
type Category = Pick<CategoryComparison, 'code'|'estimate'|'lower'|'upper'|'status'>
export type DisplayProbability = number | string
type Pair = Pick<PairComparison, 'a'|'b'|'estimate'|'lower'|'upper'|'status'> & {pValue:string; holmP:DisplayProbability}
type Test = Pick<JointComparison, 'kind'|'status'> & {pValue:string|null}
export interface DisplayComparison {
  readonly compactScope: 'MONDAY_FRIDAY'|'ORIGINAL_FACTOR_SCOPE'
  readonly plannedCategoryCodes: readonly string[]
  readonly activeCategoryCodes: readonly string[]
  readonly categories: readonly Category[]
  readonly pairs: readonly Pair[]
  readonly unavailablePairs: readonly {readonly a:string; readonly b:string; readonly status:'UNAVAILABLE'}[]
  readonly tests: readonly Test[]
}
export type DisplayComparisonLoader = (key:FitKey, signal:AbortSignal) => Promise<DisplayComparison>

function requireField(condition:unknown): asserts condition {
  if (!condition) throw new Error('Invalid component display data')
}
function record(value:unknown, fields:readonly string[]): Record<string,unknown> {
  requireField(typeof value==='object' && value!==null && !Array.isArray(value))
  const obj=value as Record<string,unknown>
  requireField(Object.keys(obj).length===fields.length && fields.every(k=>Object.prototype.hasOwnProperty.call(obj,k)))
  return obj
}
function finite(value:unknown): number {
  requireField(typeof value==='number' && Number.isFinite(value))
  return value
}
function probability(value:unknown): number {
  const n=finite(value)
  requireField(n>=0 && n<=1)
  return n
}
export function isPrintedProbability(value:unknown): value is string {
  return typeof value==='string' && (value==='<0.001' || /^(?:0\.(?!000)[0-9]{3}|1\.000)$/.test(value))
}
export function formatProbability(value:DisplayProbability|null|undefined): string {
  if (value==null) return 'Unavailable'
  if (typeof value==='string') {
    requireField(isPrintedProbability(value))
    return value
  }
  return value < .001 ? '<0.001' : value.toFixed(3)
}
export function overallProbability(value:DisplayProbability|null|undefined): string {
  const label=formatProbability(value)
  return label==='Unavailable' || label==='<0.001' ? label : '= '+label
}
function printed(value:unknown): string {
  requireField(isPrintedProbability(value))
  return value
}
function interval(row:unknown[]) {
  const estimate=finite(row[0]), lower=finite(row[1]), upper=finite(row[2])
  requireField(lower<=estimate && estimate<=upper)
  return {estimate, lower, upper}
}
export function componentDisplayKey(key:FitKey): string {
  return ['components',key.population,key.model,key.factor,key.outcome].join('/')
}
export function validateComponentDisplay(key:string, value:unknown): DisplayComparison {
  const parts=key.split('/')
  const [,pop,model,factor,outcome]=parts
  requireField(parts.length===5 && parts[0]==='components' && populations.includes(pop!) &&
    (model==='BASE'||model==='FULL') && Object.prototype.hasOwnProperty.call(componentCategories,factor!) && outcomes.includes(outcome!))
  const data=record(value,['schema','key','within','pairs','overall'])
  requireField(data.schema==='component-display-v1' && data.key===key)
  const codes=componentCategories[factor as ComponentFactor]
  requireField(Array.isArray(data.within) && data.within.length===codes.length)
  const categories:Category[]=data.within.map((row:unknown,i:number)=>{
    if(row===null)return {code:codes[i]!,estimate:null,lower:null,upper:null,status:'UNAVAILABLE'}
    requireField(Array.isArray(row) && row.length===3)
    return {code:codes[i]!,...interval(row),status:'COMPUTED'}
  })
  const active=categories.filter(c=>c.status==='COMPUTED').map(c=>c.code)
  requireField(active.length>0 && (factor!=='wdy_donation'||active.length===5))
  requireField(Array.isArray(data.pairs) && data.pairs.length===codes.length*(codes.length-1)/2)
  const pairs:Pair[]=[], unavailablePairs:{a:string;b:string;status:'UNAVAILABLE'}[]=[]
  let idx=0
  for(let i=0;i<codes.length;i++)for(let j=i+1;j<codes.length;j++) {
    const a=codes[i]!,b=codes[j]!,row:unknown=data.pairs[idx++]
    const left=categories[i]!.estimate,right=categories[j]!.estimate
    if(left===null||right===null) {
      requireField(row===null)
      unavailablePairs.push({a,b,status:'UNAVAILABLE'})
      continue
    }
    requireField(Array.isArray(row) && row.length===5)
    const values=interval(row), pValue=printed(row[3])
    // Only default-reference pairs expose exact Holm values in the overview SVG tooltip.
    const holmP=i===0 ? probability(row[4]) : printed(row[4])
    const adjustedLabel=formatProbability(holmP)
    requireField(pValue==='<0.001' || adjustedLabel!=='<0.001' && pValue<=adjustedLabel)
    requireField(Math.abs(values.estimate-(left-right))<=1e-9*Math.max(1,Math.abs(values.estimate),Math.abs(left-right)))
    pairs.push({a,b,...values,pValue,holmP,status:'COMPUTED'})
  }
  // Rounded p values cannot independently reproduce Holm adjustment. The source
  // projection verifies all unrounded probabilities before creating this file.
  const overall=record(data.overall,['endpoint','trajectory'])
  const tests:Test[]=(['endpoint','trajectory'] as const).map(kind=>{
    const row=overall[kind]
    requireField(Array.isArray(row) && row.length===2 && jointStatuses.includes(row[0] as JointStatus))
    const [status,raw]=row as [JointStatus,unknown]
    requireField((status==='NOT_APPLICABLE_SINGLE_CATEGORY')===(active.length===1))
    if(status==='COMPUTED'||status==='LOW_EFFECTIVE_DF')return {kind,status,pValue:printed(raw)}
    requireField(raw===null)
    return {kind,status,pValue:null}
  })
  return {compactScope:factor==='wdy_donation'?'MONDAY_FRIDAY':'ORIGINAL_FACTOR_SCOPE',
    plannedCategoryCodes:codes,activeCategoryCodes:active,categories,pairs,unavailablePairs,tests}
}
