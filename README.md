# Seat Majorities without Vote Majorities

Replication package for the paper "Seat Majorities without Vote Majorities:
Coalition Inversions in Brazil's Chamber of Deputies."

The repository computes whether party coalitions in Brazil's Chamber of
Deputies hold a seat majority without a national federal-deputy vote majority.
It covers distinct election-year cabinet party sets and ideologically constrained
potential coalitions for the mandates tied to the 2014, 2018, and 2022
elections. The primary ideological analysis filters the existing election-year order to
seat-winning parties (`seat_winning`). Exact-connected intervals form the
\(k=0\) domain; \(k=1\) allows one omitted interior seat-winning party. The
original full ideological order is generated independently as `all_parties`
robustness. Both universes retain **all valid federal-deputy votes** in the
national denominator. Observed cabinet memberships and coverage come from the pinned public dataset described below.

## Build and validation

From this repository, with the existing numerical environment available:

```bash
make paper       # frozen inputs -> analysis -> results -> assets -> manuscript
make test        # rebuild analysis, then scientific unit/integration and compact regressions
make test-deep   # normal suite plus exhaustive domains/A/B and extracted replication reconstruction
make package     # package the already compiled manuscript and referenced assets
make replication # package frozen inputs and code needed to reproduce the full results
```

`make paper` regenerates scientific results from scratch. It writes only under
`build/`. `make clean` removes that owned tree. A manuscript edit needs only
`make compile`; edited provenance selectors additionally need `make results`.
`make figures` and `make tables` regenerate their own assets from existing results.
A missing or failed generator cannot silently supply an old asset to compilation.
LaTeX uses latexmk with the manuscript's existing Biber bibliography backend.

Set `PYTHON_BIN` or `JULIA_BIN` if needed. The default Julia wrapper retains
Julia 1.12.7, generic CPU, disabled compiled modules/package images, one compute
thread and one GC thread. The unchanged Project.toml and Manifest.toml remain
in `processing/Processing/`. No dependency update is part of these commands.
The demonstrated Python environment is Python 3.12.1, numpy 2.4.4, pandas 3.0.2,
matplotlib 3.10.9 and Pillow 12.2.0; the project has no complete Python lock.
Caches stay in `build/cache`; already installed Julia dependencies may be read
from the user's existing depot. No package installation is run automatically.

## Frozen scientific inputs

`data/cabinet/` contains the complete four-file public cabinet snapshot:
`cabinet_periods.csv`, `cabinet_sensitivity_periods.csv`, `cabinet_coverage.csv`,
and `metadata.json`. `data/cabinet_release.json` pins that snapshot. All four are
required, including coverage and finite scenarios. Cabinet production and
historical adjudication belong to the independent cabinet project and are never
called by this manuscript build.

`data/frozen_electoral_inputs.json` identifies the nine election CSVs (candidate,
party-municipality-zone, seats for 2014/2018/2022) and two identity/lineage tables.
Their existing integrity pins are checked before analysis. The fixed ideological
inputs are `scrape_classification/output/classificacao_2023/party_ordinal_classificacao.json`
and `scrape_classification/output/classificacao_2025/party_classificacao_2025.csv`.
These inputs are preserved, not refreshed. All are included in `make replication`.

## Results and manuscript assets

The dependency direction is frozen inputs -> canonical analysis -> scientific
CSV results -> figures/tables -> manuscript -> publication package.
`build/results/domains/` retains the complete ideological domain and chronology
schemas. `build/results/accounting/` holds exact coalition/party/district results,
case/member vectors, full rankings and compact summaries. The domain and exact
accounting schemas are distinct. `build/results/cabinet/` holds quantified public
calendars; `build/results/cabinet_sets/` holds identities, occurrences, links and
finite scenarios. Exact set vectors live only in accounting.

`build/results/accounting/raw/coalition_accounting.csv.gz` contains one exact
account per election and canonical member set. `ideology_k_gap_*_both_universes`
retain complete universe/k domains and full gzip member vectors. Full coverage,
minimality and both scientific universes remain reproducible; exports are never
restricted to inversions. Cross-domain coordinates use one CSV with the existing
`ideological_universe` and `k` discriminators; the identical cabinet slice occurs
once. No renderer recomputes electoral accounting or domain minimality.

`build/results/manuscript_results.csv` provides the compact empirical prose
operands. The manuscript's local semantic selectors and literal writing workflow
remain; values are selected from canonical sources, never from expected prose.
`make compile` validates against the compact file, while `make test` also verifies
the original source selection. No byte-level manuscript acceptance is required.

The authoritative source remains
`writing/submission_inversions_review/manuscript/main_rw_again.tex`, with adjacent
`refs2.bib`. It reads every generated figure/table directly from `build/assets/`.
`build/manuscript/main_rw_again.pdf` is the compiled paper. The only figure
entrypoints are `scripts/make_figures.py` and `scripts/make_representation_profile.jl`;
the latter preserves the existing Julia/PyPlot renderer. `scripts/make_tables.py`
renders the six retained table fragments, including all four compact appendices.

| Asset in build/assets | Manuscript reference | Canonical input under build/results | Producer |
|---|---|---|---|
| party_representation_profile.pdf | Figure 1 | domains/figure_data/party_vote_share_vs_seat_share.csv | make_representation_profile.jl |
| observed_coalition_timeline.pdf | Figure 2 | domains/raw/cabinet_party_sets.csv; cabinet status/missing intervals | make_figures.py |
| minimal_connected_winning_inversions_3x1_diamond.png | Figure 3 | domains/figure_data/ideological_interval_heatmap.csv; ideology orders | make_figures.py |
| ideological_interval_heatmap_2014.pdf | Figure 4, 2014 | same heatmap and orders | make_figures.py |
| ideological_interval_heatmap_2018.pdf | Figure 4, 2018 | same heatmap and orders | make_figures.py |
| ideological_interval_heatmap_2022.pdf | Figure 4, 2022 | same heatmap and orders | make_figures.py |
| ideological_interval_heatmap_legend.pdf | Figure 4 legend | same heatmap categories | make_figures.py |
| cross_domain_components.pdf | Figure 5 | domains/figure_data/cross_domain_components.csv | make_figures.py |
| cabinet_membership_inversions.pdf | Figure 6 | accounting/raw/cabinet_party_set_accounting.csv; domains/raw/ideology_order_*.csv | make_figures.py |
| table_observed_inversion_decomposition.tex | tab:cabinet-inversions | accounting/raw/cabinet_party_set_accounting.csv | make_tables.py |
| table_accounting_minimal_ideological.tex | tab:minimal-intervals | accounting/tables/table_accounting_minimal_ideological.csv | make_tables.py |
| table_appendix_cabinet_membership_compact.tex | tab:full-cabinet-composition | accounting/raw/cabinet_party_set_accounting.csv | make_tables.py |
| table_appendix_baseline_intervals_compact.tex | tab:minimal-connected-winning-intervals | domains/tables/table_appendix_minimal_connected_winning_intervals.csv | make_tables.py |
| table_appendix_selected_party_contributions.tex | tab:coalition-party-component-extremes | accounting/tables/table_coalition_party_component_extremes.csv | make_tables.py |
| table_appendix_domain_counts_compact.tex | tab:one-gap-summary; tab:ideological-universe-comparison | domains/tables/ideological_universe_comparison.csv | make_tables.py |

The diamond PDF companion and four retained diagnostic plots also have one
producer in make_figures: vote/seat scatter, decomposition components, state
weighting anatomy and district weight. Exhaustive independent coalition/minimality rechecks run only in `make test-deep`.
Independent A/B plots are generated only
by `make test-deep` in `build/validation/party_AB/`, alongside their complete validated
CSV results. The old 80-page intermediate accounting PDF was only a view;
its exact panels, case/member/district vectors, rankings and independent tests
remain. Its human-readable report and expansive LaTeX generators are retired.

## Packaging and generated-file policy

`build/submission/publication.zip` contains the current TeX, bibliography, PDF,
and all 15 referenced assets. Asset references are mechanically localized inside
the ZIP; no scientific work or rendering occurs during packaging. The package
checks actual membership and bytes when generated, without a permanent manifest.

`build/submission/replication.zip` contains frozen inputs, code, tests, environment
specifications and manuscript sources sufficient to regenerate all advertised
results with `make paper` and `make test`. Language runtimes, installed package
caches and TeX distribution must already be available. This archive is separate
from the journal source package and does not include historical review packages.

Generated CSVs, figures, TeX fragments, logs, PDFs, caches and ZIPs are ignored
under `build/` and should be regenerated. Frozen inputs and code remain versioned.
Old paper/decomposition mirrors, manuscript-local generated copies and historical
handoffs have no live build consumer. No normal target reads migration baselines,
retired repair/audit trees, the original project or cabinet producer internals.

Tests require the documented runtimes and fail when a module, fixture or frozen input
is absent. `make test` builds its analysis/results prerequisites and does not require
presentation assets. Small exact examples and an exhaustive subset oracle localize
accounting/domain failures; integration tests check all 52 exported cabinet scenarios.
The small expected-result fixtures under `processing/tests/fixtures/` are frozen
reference values, not snapshots regenerated from the implementation. No normal or
deep test reads sibling projects or migration baselines. Full paper compilation and
extracted replication are build integration checks; pixels and page counts are not
permanent test obligations. `make test-deep` also exports a source package, extracts it into a fresh temporary
directory and compares the scientific CSV/gzip payloads produced by analysis/results. `make test test-deep`
runs their shared prerequisite once.

## Repository scope

The shallow tree contains `data/` (frozen inputs), `processing/` (Julia project,
scientific code and tests), `scrape_classification/` (the two frozen ideology
inputs), `scripts/` (build and packaging commands), `writing/` (current manuscript,
bibliography and presentation tests), and disposable `build/` output. The
`processing/Processing/` name is the active Julia project location; it is retained
with its Project/Manifest and current code, not an obsolete output hierarchy.

Historical acquisition, dashboards, exploratory vote exporters, R&R drafts and
repair workflows are outside this project’s supported commands. Their archived
implementations remain in the protected historical reference. Reconstruction
uses the frozen inputs above and never needs that reference or migration files.
