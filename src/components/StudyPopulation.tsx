import { useEffect, useId, useState } from 'react'
import './studyPopulation.css'
import { POPULATIONS, type FitKey, type ValidatedRelease } from '../data/release'
import { POPULATION_LABELS, POPULATION_NOTES, FULL_MODEL_NOTE, PRIMARY_CHANGE_NOTE, REFERENCE_PROFILE_NOTE, PARITY_NOTE } from '../data/display'
import { loadReport } from '../data/loader'
import { isWithheld, readDisplay } from '../data/reader'
import { studyCategoryStatus, studyRowCode, validateStudyDisplay, type StudyDisplay } from '../data/studyDisplay'
import type { ValidatedSupplement } from '../data/supplements'
import { STUDY_REPORT_ROLES, COUNT_META, FACTOR_META, adapt, projectStudy, sapsHasNoMissing, value,
  type CountUnit, type Numeric, type PopulationData } from '../data/studyReports'

interface Props {
  release: ValidatedRelease | null
  supplement: ValidatedSupplement | null
  supplementState: 'loading' | 'missing' | 'ready' | 'error'
  assetBase: string
  displayReleaseId?: string
}

function CountSection({ label }: { label: string }) {
  return <tr className="table-section-row count-section-row"><th scope="rowgroup">{label}</th><th scope="col" className="summary-number">n</th><th scope="col" className="summary-parenthesis">(%)</th></tr>
}
function SummaryColumns() {
  return <colgroup><col className="study-label-column"/><col className="study-number-column"/><col className="study-bracket-column"/></colgroup>
}
function SummaryCells({ main, bracket, digits = 1, status, annotation }: { main: Numeric; bracket?: readonly [Numeric] | readonly [Numeric, Numeric]; digits?: number; status?: string; annotation?: string }) {
  return <><td className={`summary-number${main === null || status ? ' summary-text' : ''}`}>{status ?? value(main, digits)}{bracket || annotation ? ' ' : null}</td><td className="summary-parenthesis">{bracket && !status ? <>({bracket.map(item => value(item)).join(' to ')})</> : null}{annotation && <span className="category-note">{annotation}</span>}</td></>
}

export default function StudyPopulation({ release, supplement, supplementState, assetBase, displayReleaseId }: Props) {
  const compact = displayReleaseId !== undefined
  const selectId = useId()
  const [population, setPopulation] = useState<FitKey['population']>('PRIMARY')
  const [retry, setRetry] = useState(0)
  const [sapsCompleteness, setSapsCompleteness] = useState<{ key: string; complete: boolean } | null>(null)
  const [loaded, setLoaded] = useState<{ key: string; state: 'ready' | 'error' | 'withheld'; data?: PopulationData; display?: StudyDisplay } | null>(null)
  const compatible = release !== null && supplement !== null && release.manifest.releaseId === supplement.manifest.releaseId
    && release.manifest.datasetKind === supplement.manifest.datasetKind
  const selection = JSON.stringify([displayReleaseId, assetBase, release?.manifest.releaseId, supplement?.manifest.coreManifestSha256, population])
  const current = loaded?.key === selection ? loaded : null
  useEffect(() => {
    if (compact) {
      const key = `study/${population}`, controller = new AbortController()
      setLoaded(null)
      readDisplay(key, controller.signal).then(raw => validateStudyDisplay(key, raw)).then(display => {
        if (!controller.signal.aborted) setLoaded({ key: selection, state: 'ready', display })
      }).catch((reason: unknown) => {
        if (!controller.signal.aborted) setLoaded({ key: selection, state: isWithheld(reason) ? 'withheld' : 'error' })
      })
      return () => controller.abort()
    }
    if (supplementState !== 'ready' || !compatible || !supplement) return
    const controller = new AbortController()
    setLoaded(null)
    Promise.all([
      Promise.all(STUDY_REPORT_ROLES.map(role => loadReport(supplement, { scope: 'population', population }, role, assetBase, controller.signal))),
      loadReport(supplement, { scope: 'population', population }, 'rdd_patient_age_groups', assetBase, controller.signal).catch(() => null),
    ])
      .then(([tables, ageGroups]) => {
        const data = adapt(tables, ageGroups)
        if (!controller.signal.aborted) setLoaded({ key: selection, state: 'ready', data })
      })
      .catch(() => { if (!controller.signal.aborted) setLoaded({ key: selection, state: 'error' }) })
    return () => controller.abort()
  }, [compact, supplement, supplementState, compatible, population, assetBase, selection, retry])
  const completenessKey = JSON.stringify([assetBase, release?.manifest.releaseId, supplement?.manifest.coreManifestSha256])
  useEffect(() => {
    if (compact || supplementState !== 'ready' || !compatible || !supplement) return
    const controller = new AbortController()
    setSapsCompleteness(null)
    Promise.all(POPULATIONS.map(async code => sapsHasNoMissing(
      await loadReport(supplement, { scope: 'population', population: code }, 'rdd_patient_saps', assetBase, controller.signal), supplement.manifest.releaseId, code,
    ))).then(values => { if (!controller.signal.aborted) setSapsCompleteness({ key: completenessKey, complete: values.every(Boolean) }) })
      .catch(() => { if (!controller.signal.aborted) setSapsCompleteness({ key: completenessKey, complete: false }) })
    return () => controller.abort()
  }, [compact, supplement, supplementState, compatible, assetBase, completenessKey, retry])
  const data = current?.display ?? (current?.data
    ? projectStudy(current.data, sapsCompleteness?.key === completenessKey && sapsCompleteness.complete)
    : undefined)
  const parity = data?.units.find(group => group.factor === 'DonorParity')
  return <section className="study-population" aria-labelledby="population-heading">
    <div className="figure-heading"><div><h2 id="population-heading">Study population and methods</h2><p>Patient characteristics and the RBC units included in the analysis.</p></div></div>
    <div className="controls population-controls"><label htmlFor={selectId}>Analysis population<select aria-label="Analysis population" id={selectId} value={population} onChange={event => setPopulation(event.target.value as FitKey['population'])}>{POPULATIONS.map(code => <option key={code} value={code}>{POPULATION_LABELS[code]}</option>)}</select></label></div>
    <p className="report-note">{POPULATION_NOTES[population]}</p>
    {release?.manifest.datasetKind === 'development_sample' && <p className="report-note">Development sample: these are not final study counts.</p>}
    {current?.state === 'withheld' ? <div className="report-empty" role="status">The selected population summaries are withheld from this release.</div> : !compact && supplementState === 'missing' ? <div className="report-empty" role="status">Population summaries are not yet available for this release.</div>
      : !compact && (supplementState === 'error' || (supplementState === 'ready' && !compatible)) ? <div className="error" role="alert">Population-summary metadata could not be verified.</div>
      : !compact && (!release || supplementState === 'loading') ? <div className="report-empty" role="status">Loading population summaries...</div>
      : current?.state === 'error' ? <div className="error" role="alert"><p>Population summaries could not be verified or loaded.</p><button onClick={() => setRetry(previous => previous + 1)}>Try again</button></div>
      : !data ? <div className="report-empty" role="status">Loading population summaries...</div>
      : <>
        <p className="table-scroll-hint">Scroll horizontally within a table to see all columns.</p>
        <div className="population-summary">{(Object.keys(COUNT_META) as CountUnit[]).map(unit => <div className="summary-card" key={unit}><span>{COUNT_META[unit].label}</span><strong>{value(data.counts[unit], 0)}</strong></div>)}</div>
        <p className="report-note">Patient characteristics describe each person once at their first eligible event in this population. Model-specific complete cases can be fewer. Units are physical RBC units linked to eligible index events, rather than all transfusions received.</p>
        <div className="study-tables">
        <section className="report-section study-table-section" aria-labelledby="patient-characteristics">
          <h3 id="patient-characteristics">Patient characteristics</h3>
          <p className="study-table-subtitle">{POPULATION_LABELS[population]} &middot; {value(data.counts.PERSONS, 0)} patients</p>
          <div className="table-scroll" tabIndex={0} role="region" aria-label="Patient characteristics table"><table className="data-table publication-table">
            <caption>Characteristics at the first eligible event</caption><SummaryColumns/><thead className="study-column-definitions"><tr><th scope="col">Characteristic</th><th scope="colgroup" colSpan={2} className="summary-heading">Summary</th></tr></thead><tbody>
            <CountSection label="Recipient sex"/>
            {data.sex.map(([label, count, percent]) => <tr key={label} data-category={studyRowCode('sex', label)}><th scope="row">{label}</th><SummaryCells main={count} bracket={[percent]} digits={0}/></tr>)}
            <tr className="table-section-row"><th colSpan={3} scope="rowgroup">Age at the first eligible event <span>Years</span></th></tr>
            <tr data-statistic="age-mean"><th scope="row">Mean (SD)</th><SummaryCells main={data.age.mean[0]} bracket={[data.age.mean[1]]}/></tr>
            <tr data-statistic="age-median"><th scope="row">Median (IQR)</th><SummaryCells main={data.age.median[0]} bracket={[data.age.median[1], data.age.median[2]]}/></tr>
            {data.ageBands === null ? <tr><th scope="row">Age groups</th><SummaryCells main={null}/></tr> : data.ageBands.map(([label, count, percent]) => <tr key={label} data-age-band={studyRowCode('ageBands', label)}><th scope="row">{label}</th><SummaryCells main={count} bracket={[percent]} digits={0}/></tr>)}
            <CountSection label="RBC units at eligible events per patient"/>
            {data.unitsPerPatient.length === 0 ? <tr><th scope="row">Units per patient</th><SummaryCells main={null}/></tr> : data.unitsPerPatient.map(([label, count, percent]) => <tr key={label} data-unit-band={label}><th scope="row">{label}</th><SummaryCells main={count} bracket={[percent]} digits={0}/></tr>)}
            <tr className="table-section-row"><th colSpan={3} scope="rowgroup">SAPS 3 at the first eligible event</th></tr>
            <tr data-statistic="saps-mean"><th scope="row">Mean (SD)</th><SummaryCells main={data.saps.mean?.[0] ?? null} bracket={[data.saps.mean?.[1] ?? null]} status={data.saps.mean === null ? 'Not requested' : undefined}/></tr>
            <tr data-statistic="saps-median"><th scope="row">Median (IQR)</th><SummaryCells main={data.saps.median?.[0] ?? null} bracket={[data.saps.median?.[1] ?? null, data.saps.median?.[2] ?? null]} status={data.saps.median === null ? 'Not requested' : undefined}/></tr>
            <tr><th scope="row">Available numeric score, n (%)</th><SummaryCells main={data.saps.available[0]} bracket={[data.saps.available[1]]} digits={0}/></tr>
            {data.saps.missing !== null && <tr><th scope="row">Unknown, n (%)</th><SummaryCells main={data.saps.missing[0]} bracket={[data.saps.missing[1]]} digits={0}/></tr>}
            <tr><th scope="row">Not interpretable as a numeric score, n (%)</th><SummaryCells main={data.saps.invalid[0]} bracket={[data.saps.invalid[1]]} digits={0}/></tr>
            {data.saps.notRequested.length === 1 && <tr><th scope="row">Not requested, n</th><SummaryCells main={data.saps.notRequested[0]} digits={0}/></tr>}
          </tbody></table></div>
          <div className="study-table-notes">
            <p>Values are n (%) unless specified otherwise. Patient percentages use all {value(data.counts.PERSONS, 0)} eligible patients as the denominator. Age summaries use {value(data.age.available, 0)} available values; age missing: {value(data.age.missing, 0)}. SD, standard deviation; IQR, first to third quartile.</p>
            {data.saps.allPopulationsComplete && <p className="saps-completeness-note">No blank SAPS 3 entries were recorded in any of the three analysis populations; nonnumeric entries are reported separately.</p>}
            <p>Unit counts include physical RBC units linked to eligible events in this population, not all ICU transfusions. Units starting at the same time can belong to one event.</p>
            <p>SAPS 3 describes illness severity and was not included in model adjustment. Summaries use recorded numeric scores. Values that could not be read as a numeric score were distinguished from missing values; no clinical plausibility range was applied. Unknown includes information that was not recorded or could not be classified; these reasons are shown separately.</p>
          </div>

        </section>
        <section className="report-section study-table-section" aria-labelledby="unit-characteristics">
          <h3 id="unit-characteristics">Donor and component characteristics</h3>
          <p className="study-table-subtitle">{value(data.counts.LINKED_PHYSICAL_UNITS, 0)} physical RBC units linked to eligible events</p>
          {data.units.length === 0 ? <p className="report-empty">No unit-category rows were supplied.</p> : <div className="study-component-tables">{data.units.map(group => <div className="study-unit-group" key={group.factor} data-factor={group.factor}>
            <div className="table-scroll" tabIndex={0} role="region" aria-label={`${FACTOR_META[group.factor].label} table`}><table className="data-table publication-table">
              <caption>{FACTOR_META[group.factor].label}: linked index units</caption><SummaryColumns/><thead><tr><th scope="col">{FACTOR_META[group.factor].label}</th><th scope="col" className="summary-number">n</th><th scope="col" className="summary-parenthesis">(%)</th></tr></thead><tbody>
              {group.rows.map(([label, count, percent]) => {
                const code = studyRowCode(group.factor, label)
                return <tr key={code} data-category={code} data-record-status={studyCategoryStatus(label)}><th scope="row">{label}</th><SummaryCells main={count} bracket={[percent]} digits={0}/></tr>
              })}
            </tbody></table></div>
            {group.coverage && <p className="study-denominator">{group.coverage}</p>}
          </div>)}</div>}
          <div className="study-table-notes"><p>Values are n (%). Percentages use all {value(data.counts.LINKED_PHYSICAL_UNITS, 0)} linked index units. {parity && <>Parity percentages use female-donor units only (n = {value(parity.parityDenominator ?? null, 0)}). </>}{PARITY_NOTE}</p><p>The donor sex table combines male-donor units with units whose donor sex was unrecorded or could not be classified. The donation-day table combines Saturday and Sunday. Model comparisons use Monday to Friday.</p></div>
        </section>
        </div>

      </>}
    <details className="report-section supporting-section"><summary>Analysis and definitions</summary>
      <h3>Transfusion events</h3><p className="report-note">{POPULATION_NOTES.PRIMARY} RBC units starting at the same time form one index event. Counts of patients, events and physical units therefore describe different things.</p>
      <h3>Adjusted trajectories</h3><p className="report-note">The models included a patient-specific random intercept and flexible time curves. BASE adjusted for age, recipient sex, ward, time from ICU admission to transfusion and previous RBC units in the same admission.</p><p className="report-note">{FULL_MODEL_NOTE}</p>
      <p className="report-note">Models used measurements with complete adjustment data. Missing model variables were not imputed, and no physiological cutoffs were applied to exclude possible recording artifacts.</p>
      <h3>Change and uncertainty</h3><p className="report-note">{PRIMARY_CHANGE_NOTE} Comparisons between donor/component categories used differences between these changes, with their shared covariance.</p><p className="report-note">Confidence intervals accounted for repeated measurements within the same person, using cluster-robust CR2 inference and contrast-specific degrees of freedom. Intervals are pointwise. Pairwise p values use Holm adjustment within each reported factor–outcome–model–population family.</p>
      <p className="report-note">Donation-day comparisons were restricted to Monday–Friday; weekend observations remained in the fitted models. Where coefficients required correction, the estimated working covariance was held fixed. We recalculated the reported contrasts and their CR2 uncertainty using the corrected coefficients.</p>
      <h3>Interpretation</h3><p className="report-note">{REFERENCE_PROFILE_NOTE} Model populations can therefore differ from the patient counts above. These are observational associations.</p>
    </details>
  </section>
}
