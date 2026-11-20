# Analysis methods

The study examines seven physiological outcomes during the 12 hours before and after red blood cell transfusion start. The main contrast is the predicted value at +60 minutes minus the predicted value at −60 minutes. The results describe changes around transfusion in an observational cohort.

## Read the analysis

| Question | Source |
| --- | --- |
| Which transfusions, people and measurements are eligible? | `sas/01_cohort.sas` links records, groups simultaneous units and applies eligibility and sensitivity definitions. |
| How are donor and unit characteristics coded? | `sas/00_categories.sas` defines categories. `sas/01_cohort.sas` checks whether units at the same event share a category. |
| How are observed changes calculated? | `sas/02_summaries.sas` calculates descriptive and paired-window summaries. `sas/05_loess.sas` fits descriptive curves. |
| How are predicted changes and their uncertainty calculated? | `sas/03_models.sas` fits the mixed models and defines reference profiles. `sas/04_inference.sas` and the numerical modules in `python/` calculate and validate robust inference. |
| How were weekday comparisons defined? | `sas/07_weekday.sas`, `weekday_models.csv` and `weekday_settings.json` specify the comparisons and the coefficient solution used for each analysis. |

**Cohort.** The analysis links recorded index events to an ICU admission and to individual transfused red cell units. Multiple units at the same start time count as one event. A preceding red cell transfusion in the 12 hours up to the index event, including exactly 12 hours before it, excludes the event. The main population includes all eligible events. One sensitivity analysis uses the first eligible event per person. The other uses events with no further recorded red cell unit during the next 12 hours and with that observation window inside the recorded transfusion history.

**Models.** Each model uses the available measurements with the outcome and all model-specific covariates present. The BASE model includes time from transfusion, age, time from ICU admission to transfusion, the number of preceding red cell units in that admission, sex and ward. Time from transfusion, age and ICU time enter as splines. FULL, the primary model, also includes crystalloid, noradrenaline and sedative/analgesic treatment summaries over the 1 and 24 hours before each measurement. This timing can include treatment after transfusion. The continuous crystalloid and noradrenaline variables enter as splines and the sedative variables as indicators of positive recorded values. BASE and FULL can use different observations and different reference profiles.

Models with a donor or unit factor include its interaction with the time spline. The working model uses restricted maximum likelihood and a patient-specific random intercept. Predictions use the model-specific reference profile. Confidence intervals use patient-cluster CR2 inference. Scalar contrasts use contrast-specific Satterthwaite degrees of freedom. The code distinguishes unavailable inference from a computed zero.

**Donation weekday.** A reporting amendment made during the analysis restricted reported donation-day comparisons to Monday through Friday. Weekend observations remained in the fitted models. The analysis counted donations on all seven days. The dashboard combines Saturday and Sunday in its descriptive tables. The five reported days give ten pairwise comparisons per family, with Holm adjustment. Fourteen of the 42 weekday analyses kept the fixed-effect estimates from the original seven-day fit. Their five-day contrasts reused the saved scalar estimates and their patient-cluster CR2 uncertainty. The two joint tests were recalculated for Monday through Friday.

The BASE model for mean arterial pressure in the population with no further unit within 12 hours kept the original coefficients and used the full residual scale in the numerical check. In the remaining 27 analyses, a whitened residual component exceeded the allowed tolerance in a direction where the fitted model requires zero. Generalized least squares then updated the coefficients with the working covariance held fixed, and the contrasts and their CR2 uncertainty were recalculated. The model assignments and residual-scale rule are recorded in [weekday_models.csv](weekday_models.csv) and [weekday_settings.json](weekday_settings.json). The [weekday inference routine](sas/07_weekday.sas) implements the residual check and the [coefficient calculation](python/weekday_mean.py) implements the fixed-covariance update.

## Inspect or run the code

Run `python run.py plan` from this directory to display the combinations in `models.csv`. This command needs no clinical data or SAS installation. The selected results comprise 210 main or nonweekday analyses and 42 weekday analyses. The study estimates came from earlier full-cohort analyses. The original observations remain restricted. Re-estimating the study results requires the three restricted input tables. [Input variables and definitions](INPUTS.md)

For an authorized analysis, use SAS 9.4 for Windows with Base SAS, SAS/STAT and SAS/IML. Use Python 3.13.5 to match the documented numerical environment. The dependency file pins NumPy 2.3.2, SciPy 1.16.1, threadpoolctl 3.6.0 and pyreadstat 1.3.1, and requires pandas for the data-frame interface to pyreadstat. The dependency file does not specify a pandas version. Install the dependencies in a dedicated environment.

```sh
python -m pip install -r requirements.txt
```

Store two copies of `config.example.json` outside this repository: one for the SAS startup check and one for the analysis. Supply the installed SAS executable and UTF-8 configuration, a directory containing the three SAS members, their member names, a nonidentifying input version, the cohort mode and a new output directory outside the repository and input directory. To check that SAS can start and load the macros, use `python run.py check --config "<startup-check-config>"` with a **separate new output directory**. Preparation also requires a directory that does not yet exist.

In the commands below, replace `<analysis-config>` with the location of the analysis configuration file. The `models` stage includes the seven-day parent fits used by the weekday analyses. Each weekday result occupies its corresponding slot in the 252-result selection.

```sh
python run.py prepare --config "<analysis-config>"
python run.py reports --config "<analysis-config>"
python run.py models --config "<analysis-config>" --all-models
python run.py loess --config "<analysis-config>"
python run.py validate --config "<analysis-config>"
python run.py convert --config "<analysis-config>"
python run.py weekdays --config "<analysis-config>" --all-weekdays
python run.py validate-weekdays --config "<analysis-config>" --all-weekdays
python run.py convert-weekdays --config "<analysis-config>" --all-weekdays
```

Use `--model` with an identifier from `models.csv` for an individual fit. `scientific_settings.json` records the analysis specification, including settings implemented in the SAS routines. The weekday method assignments belong to this study and require the corresponding retained fit information. See the output definitions for how results proceed from validation to the dashboard. [Analysis outputs](OUTPUTS.md)
