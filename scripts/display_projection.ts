import {
  OUTCOMES, POPULATIONS, getAuthoritativeReference, validateReleaseManifest,
  type ArtifactReference, type AuthoritativeRole, type FitKey, type ValidatedRelease,
} from '../src/data/release'
import {validateResultTable} from '../src/data/tables'
import {readComparison} from '../src/data/comparisons'
import {validateSupplementManifest,validateReportTable,type ReportRole} from '../src/data/supplements'
import {validateLoessManifest,validateLoessSeries,type ArchivedCurveFormat} from '../src/data/loess'
import {studyFromReports,sapsHasNoMissing,STUDY_REPORT_ROLES} from '../src/data/studyReports'
import {OBSERVED_DISPLAY_SCHEMA,projectObservedCurve} from '../src/data/observedDisplay'
import {validateDashboardAsset} from '../src/data/validateDisplay'
import {projectTrajectory,projectEndpoint} from './main_projection'
import {projectComponent} from './component_projection'

type Reader = (ref:ArtifactReference) => unknown
export function prepareSources(core:unknown, supplement:unknown, loess:unknown, coreSha256:string) {
  const release: ValidatedRelease = {
    ...validateReleaseManifest(core,{mode:'analysis-tables'}), manifestSha256:coreSha256,
  }
  if (release.manifest.datasetKind !== 'full_cohort') {
    throw new Error('A full-cohort scientific result release is required')
  }
  return {release,supplement:validateSupplementManifest(supplement,release,coreSha256),
    loess:validateLoessManifest(loess,release,coreSha256)}
}

export function projectSelection(key:string, sources:ReturnType<typeof prepareSources>, read:Reader,
                                archivedFormat?:ArchivedCurveFormat, allStudySelected = false): unknown {
  const {release,supplement,loess} = sources
  const parts = key.split('/')
  function table(fit:FitKey,role:AuthoritativeRole) {
    const ref = getAuthoritativeReference(release,fit,role)
    return validateResultTable(read(ref),release,fit,role)
  }
  function report(population:FitKey['population'],role:ReportRole) {
    const item = supplement.manifest.reports.find(r => r.key.scope === 'population' && r.key.population === population)
    const ref = item?.state === 'accepted' ? item.files[role] : undefined
    if (!item || !ref) throw new Error('The required population report is unavailable')
    return validateReportTable(read(ref),supplement,item.key,role)
  }
  let value:unknown
  switch (parts[0]) {
    case 'main':
    case 'components': {
      const component = parts[0] === 'components'
      const [population,model] = parts.slice(1,3)
      const factor = component ? parts[3] : 'MAIN'
      const outcome = component ? parts[4] : parts[3]
      const job = release.manifest.jobs.find(({key:k}) => k.population === population && k.model === model &&
        k.factor === factor && k.outcome === outcome)
      if (!job || job.state !== 'accepted') throw new Error('The requested model is unavailable')
      if (component) {
        const comparison = readComparison(table(job.key,'within'),table(job.key,'pairwise'),table(job.key,'joint'),job.plan)
        value = projectComponent(key,comparison)
      } else {
        const role = parts[4]
        if (role !== 'levels' && role !== 'changes') throw new Error('Unknown trajectory scale')
        value = projectTrajectory(key,table(job.key,role))
      }
      break
    }
    case 'endpoints': {
      const model = parts[1]
      if (model !== 'BASE' && model !== 'FULL') throw new Error('Unknown model')
      const panels = Object.fromEntries(OUTCOMES.map(outcome => [
        outcome, Object.fromEntries(POPULATIONS.map(population =>
          [population,projectEndpoint(table({population,model,outcome,factor:'MAIN'},'within'))])),
      ]))
      value = {key,panels}
      break
    }
    case 'study': {
      const population = POPULATIONS.find(p => p === parts[1])
      if (!population) throw new Error('Unknown population')
      const tables = STUDY_REPORT_ROLES.map(role => report(population,role))
      const ageBands = report(population,'rdd_patient_age_groups')
      const complete = allStudySelected ? POPULATIONS.map(p => sapsHasNoMissing(
        p === population ? tables[STUDY_REPORT_ROLES.indexOf('rdd_patient_saps')]! : report(p,'rdd_patient_saps'),
        release.manifest.releaseId,p)).every(Boolean) : null
      value = studyFromReports(tables,ageBands,complete)
      break
    }
    case 'observed': {
      const matches = loess.manifest.series.filter(entry => entry.outcome === parts[1] && entry.scale === parts[2])
        .sort((a,b) => a.spanPercent - b.spanPercent)
      if (matches.length !== 81 || matches.some((m,i) => m.spanPercent !== i+10)) throw new Error('Incomplete observed selection')
      value = {schemaVersion:OBSERVED_DISPLAY_SCHEMA,
        curves:matches.map(entry => projectObservedCurve(validateLoessSeries(read(entry.file),loess,entry,archivedFormat)))}
      break
    }
    default: throw new Error('Unknown dashboard selection')
  }
  validateDashboardAsset(key,value)
  return value
}
