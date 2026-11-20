# Analysis outputs

## Estimates and summaries

The analysis reports predicted levels, changes relative to one hour before transfusion, and the change from one hour before to one hour after transfusion. For donor and unit factors it also reports pairwise differences in that endpoint change and joint tests. Each fitted model has its own reference profile. The paired descriptive analysis averages the measurements for each event in two windows, −65 to −55 and +55 to +65 minutes, and averages the within-event differences among events with observations in both windows. These summaries can have different denominators from the modelled estimates.

The weekday output contains levels, changes, within-category effects, pairwise differences, the endpoint joint test, the trajectory joint test and a reference profile. The dashboard combines the two joint-test outputs into one table. Intervals and tests use the uncertainty calculated for the selected coefficient solution. [Weekday analysis methods](README.md#read-the-analysis)

SAS retains the binary64 representation of each numerical result. Validation checks a model's output and associated source identifiers. `convert_results.py` writes decimal CSVs and verifies that conversion preserves those values. Prepared observation tables, native fit quantities and covariance matrices, exact-time LOESS inputs and local execution records stay in restricted storage.

## Convert checked outputs to dashboard tables

Start with a completed, validated analysis output directory. Store a UTF-8 JSON file containing the authors’ methods text outside the source checkout. Supply its path as `<methods-json-file>` below. Its fields are defined by `method_shape()` in `results/model_adapter.py`. When using methods text from an existing dashboard release, use the object under `sections` in the methods file.

From `analysis/`, run the commands below with the identifiers for that execution. `--input-snapshot-sha256` and `--analysis-package-sha256` take the corresponding 64-character SHA-256 digests. The first command writes `results.json` under the analysis output directory and prints its digest. Supply that digest to the second command. Use a fresh directory for the converted tables and a separate local path for the conversion record.

```text
python results/make_results_index.py --input-root "<analysis-output>" --input-snapshot-sha256 "<input-snapshot-digest>" --analysis-package-sha256 "<analysis-package-digest>" --methods "<methods-json-file>"
python results/model_adapter.py --input-root "<analysis-output>" --index results.json --index-sha256 "<results-index-digest>" --output "<new-output-directory>" --release-id "<release-id>" --receipt "<conversion-record-path>"
```

| Files | Contents |
| --- | --- |
| `release.json` and model tables | Selected model keys, status, predictions, contrasts and tests. Unavailable estimates retain their status. |
| `supplements.json` and its referenced files | Descriptive summaries, reference profiles and study methods. |
| `loess.json` and series files | Descriptive curves at 81 smoothing spans for seven outcomes, on the recorded and standardized scales. |

The output directory contains the normalized model and descriptive tables. To extract the values displayed in the dashboard, run this command from the project root after installing its JavaScript dependencies.

```sh
node scripts/convert.mjs "<tables-directory>" "<new-display-directory>" "<release-id>"
```

If the input tables use study-specific method and unit codes, append the recorded method code and then the recorded unit code to the command.

The new directory contains `reader.json` and the aggregate display files under `results/`. These files are the inputs to the dashboard build.
