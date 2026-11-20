# Physiological trajectories around red blood cell transfusion in intensive care

This dashboard presents modelled changes in seven physiological measurements around red blood cell transfusion. Readers can explore the main results, donor and component comparisons, sensitivity analyses, observed curves and study population summaries. The study is observational. [Open the dashboard](https://scandat.github.io/Transfusion-Dashboard-publication/)

## Run the dashboard

With Node.js 24 and npm installed, run `npm ci` and `npm run dev` from the project directory. Open the local address printed by Vite. To build the static site, run `npm run build`. Run `npm run preview` to view the built site locally.

For a site served below a subdirectory, use `npm run build -- --base=/project-name/`. The Pages workflow obtains the site path from GitHub Pages and deploys the contents of `dist/`.

## Data and methods

The `reader-data/` directory contains the aggregate summaries and curves displayed by the dashboard. The index identifies the file for each selection and its SHA-256 checksum. The analysis requires access to the underlying study data, which are held separately.

The SAS and Python files describe cohort selection, model fitting and statistical inference. The output documentation describes how the analysis tables are converted to the display format. [Analysis methods](analysis/README.md) / [Input definitions](analysis/INPUTS.md) / [Analysis outputs](analysis/OUTPUTS.md)

See the [software license](LICENSE) and the [font licenses](src/assets/fonts/README.md).
