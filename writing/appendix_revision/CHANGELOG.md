# Compact appendix follow-up

Base: `239d66b3630babc70ea2de10aaf070f45180f069`.

This follow-up tracks the existing compressed appendix deliverables, makes their
exporter independent of the cabinet reconstruction pipeline, and restores two
claims in Appendix B.2. The manuscript remains **28 pages**, with Appendices A
and B on **pages 24–28**, four compact tables, and one cabinet figure. No main-text
wording outside B.2 or main-text display was changed in this commit.

## Compact-output dependency map

Paths below are relative to `processing/Processing/output/paper/` unless stated
otherwise. `writing/make_appendix_assets.py` writes only the five manuscript
assets under `writing/submission_inversions_review/manuscript/`.

| Compact output | Authoritative inputs and checks | Manuscript dependency |
|---|---|---|
| `table_appendix_cabinet_membership_compact.tex` | `tables/table_appendix_cabinet_composition.csv`: 35 uniquely keyed primary sets, member strings, covered days and provisional days. Covered days are checked against the exported half-open `observation_intervals`, including recurrence gaps. | A.1, Table 3; `tab:full-cabinet-composition` |
| `table_appendix_baseline_intervals_compact.tex` | `tables/table_appendix_minimal_connected_winning_intervals.csv`, `raw/ideology_k_gap_minimal_accounting_both_universes.csv`, and `raw/ideology_order_{2014,2018,2022}.csv`: complete baseline selections, endpoint membership, vote/seat/accounting agreement and inversion classification before rounding. | A.2, Table 4; `tab:minimal-connected-winning-intervals` |
| `table_appendix_selected_party_contributions.tex` | `tables/table_coalition_party_component_extremes.csv`: cabinet sets 14-05 and 22-01, plus seat-winning 2022 k=0 MDB–UNIÃO; unique selections, signed/ranked component entries and exact-value agreement. | A.3, Table 5; `tab:coalition-party-component-extremes` |
| `table_appendix_domain_counts_compact.tex` | `tables/ideological_universe_comparison.csv` checked against the complete minimal-accounting CSV for both universes, both k values and all three elections. The totals in the note are computed from the selected rows. | B.1, Table 6; `tab:one-gap-summary` and `tab:ideological-universe-comparison` |
| `cabinet_membership_inversions.pdf` | Tracked cabinet-composition export plus the 2014/2022 ordinal party-order CSVs: membership markers, dates, vote shares, seats and all represented parties. | A.4, Figure 6; `fig:cabinet-membership-inversions` |

The tracked composition export repeats every consumed registry field exactly.
The cabinet table retains its original `raw/cabinet_party_sets.csv` source
annotation to preserve the accepted artifact bytes; its actual read dependency
is the tracked composition export. If the raw registry is present, the generator
requires both sources to agree. A clean checkout therefore needs neither that
ignored raw registry nor `generated/cabinet_party_sets/` to generate the appendix.
This does not change either authoritative CSV.

The generator reuses the existing layout, captions, notes, labels, rounding,
ordering, daggers and figure design. It no longer imports unrelated figure
pipeline modules, reads the untracked occurrence export, writes under
`output/paper/latex` or `output/paper/figure_data`, or overwrites the verification
report. Missing columns/files/expected rows, duplicate selections, inconsistent
counts and ambiguous cabinet inputs fail explicitly. Python 3.10+, pandas and
Matplotlib are required; the accepted PDF was reproduced with Matplotlib 3.10.9.

## Appendix B.2 correction

Immediately after “The strongest 2014 and 2022 endpoint regions persist.” the
manuscript now reports all-party k=0 PTB–PR in 2014 at **47.59 percent / 257
seats**, PP–PL in 2022 at **45.35 percent / 258 seats**, and **five positive A_C
values among six inversions**, with **MDB–UNIÃO the sole nonpositive case**.

The paragraph's structured provenance block now includes:

- `tables/ideological_universe_comparison.csv`, data rows 2 and 10, for both strongest cases;
- `tables/prose_analysis_summaries.csv`, data rows 4 and 10, for the six-inversion total and five positive within-district components;
- `raw/ideology_k_gap_minimal_accounting_both_universes.csv`, data rows 258–261 and 479–480, for all six inversions and their signs.

Row numbers exclude the CSV header. Semantic keys identify each selection.
Independent checks classify inversions using integer votes and seats, rank
strength by exact vote fractions, and use rational `A_C_exact` values for signs.

## Verification

The detailed, machine-readable results and SHA-256 values are in
`verification.json`.

```bash
python3 writing/make_appendix_assets.py
python3 processing/Processing/decomposition/validate_prose_provenance.py
cd writing/submission_inversions_review/manuscript
SOURCE_DATE_EPOCH=1789387200 FORCE_SOURCE_DATE=1 latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error main_rw_again.tex
cd ../../..
python3 writing/package_submission_assets.py
git diff --check
git diff --cached --check
```

- All five generated assets match the existing acceptance hashes in
  `processing/Processing/output/decomposition/audit/manuscript_empirical_asset_manifest.csv`.
  That manifest is unchanged. Repeated runs and reversed input-row ordering
  produce identical assets.
- Temporary fixture checks cover missing CSVs/columns/cabinet rows/baseline
  intervals/party-order rows, duplicate selected cases/domains, conflicting
  registry inputs, reordered inputs, and agreement with the existing raw registry.
- Independent B.2 source checks pass. The full provenance validator passes
  **35 blocks / 353 fields**, with no stale row-number warnings, using the
  existing local provenance CSVs described below.
- LaTeX completes with **28 pages**, no missing inputs, undefined references,
  unresolved citations, `??` markers or overfull boxes. The contribution label
  resolves to **Table 5, page 25**; the one-gap label resolves to **Table 6,
  page 27**.
- All five appendix pages were rendered and visually inspected. No clipping,
  illegible text, bad page breaks or misleading notes were found.
- The packager refreshes `manuscript/figures.zip` (9 files),
  `manuscript/tables.zip` (6 files), both `manuscript.zip` files (18 files each),
  and `publication_artifact_manifest.csv`. Every ZIP member is checked against
  the freshly built file. Both manuscript archives are identical and include
  the 28-page manuscript, all four compact tables and the cabinet figure.
  The stale 42-page manuscript is absent; no LaTeX auxiliaries are packaged.
- The staged tree is exported without local untracked files to verify generation
  and compilation before committing. The resulting commit is checked again from
  a clean checkout. No auxiliary files, logs or caches are committed.

## Preserved local work and remaining limitation

The original working tree contained an unrelated Section 2 sentence edit and a
modified compiled PDF. Both are preserved in the working tree. The commit and
submission bundles use the base manuscript plus only the B.2 correction.
Other untracked work is untouched.

A pristine checkout still cannot run the existing full-manuscript provenance
validator or packager without these preexisting untracked inputs:

- `generated/cabinet_party_sets/cabinet_party_sets.csv`
- `generated/cabinet_party_sets/occurrences.csv`
- `generated/cabinet_party_sets/summary.csv`

For this follow-up, those existing CSVs were copied unchanged into the isolated
packaging build solely for provenance validation; their hashes are recorded in
`verification.json`. They are not generator or LaTeX dependencies and are not
added to this commit. The full replication pipeline, cabinet-party-set scripts,
pinned V6 release and generated cabinet directory were not repaired or rebuilt.
