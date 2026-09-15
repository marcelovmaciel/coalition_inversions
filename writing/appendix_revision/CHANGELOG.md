# Compact appendix verification

The compact appendix presents supporting coalition data and ideological-domain
robustness in four tables and one figure. The generator reads existing
empirical CSVs, validates their semantic relationships, and preserves the
captions, notes, labels, rounding, ordering and layout.

## Five-output dependencies

Input paths below are relative to `processing/Processing/output/paper/`.
Outputs are under `writing/submission_inversions_review/manuscript/`.

| Compact output | Authoritative inputs and checks | Manuscript dependency |
|---|---|---|
| `table_appendix_cabinet_membership_compact.tex` | `tables/table_appendix_cabinet_composition.csv`: 35 uniquely keyed primary sets, member strings, covered days and provisional days. Covered days are checked against the exported half-open `observation_intervals`, including recurrence gaps. | A.1, Table 3; `tab:full-cabinet-composition` |
| `table_appendix_baseline_intervals_compact.tex` | `tables/table_appendix_minimal_connected_winning_intervals.csv`, `raw/ideology_k_gap_minimal_accounting_both_universes.csv`, and `raw/ideology_order_{2014,2018,2022}.csv`: complete baseline selections, endpoint membership, vote/seat/accounting agreement and inversion classification before rounding. | A.2, Table 4; `tab:minimal-connected-winning-intervals` |
| `table_appendix_selected_party_contributions.tex` | `tables/table_coalition_party_component_extremes.csv`: cabinet sets 14-05 and 22-01, plus seat-winning 2022 k=0 MDB–UNIÃO; unique selections, signed/ranked component entries and exact-value agreement. | A.3, Table 5; `tab:coalition-party-component-extremes` |
| `table_appendix_domain_counts_compact.tex` | `tables/ideological_universe_comparison.csv` checked against the complete minimal-accounting CSV for both universes, both k values and all three elections. The totals in the note are computed from the selected rows. | B.1, Table 6; `tab:one-gap-summary` and `tab:ideological-universe-comparison` |
| `cabinet_membership_inversions.pdf` | Tracked cabinet-composition export plus the 2014/2022 ordinal party-order CSVs: membership markers, dates, vote shares, seats and all represented parties. | A.4, Figure 6; `fig:cabinet-membership-inversions` |

The cabinet table reads the tracked composition export. Its source annotation
identifies the underlying raw registry; when that registry is available, the
generator also checks that all consumed fields agree. Appendix generation and
packaging work from tracked files alone. PDF producer metadata is not an
empirical acceptance criterion; figure labels, clipping and overlap are checked.

## Appendix B.2 correction

For all-party k=0, there are six inversions and five have positive A_C.
The sole nonpositive case is 2022 MDB–UNIÃO. The strongest cases are
2014 PTB–PR at **47.59 percent / 257 seats** and
2022 PP–PL at **45.35 percent / 258 seats**.

These checks use `raw/ideology_k_gap_minimal_accounting_both_universes.csv`,
selected by election, universe, k and endpoint parties, with integer votes/seats
and exact A_C signs. The corresponding summaries are in
`tables/ideological_universe_comparison.csv` and
`tables/prose_analysis_summaries.csv`.

## Verification

Run from the repository root; use an isolated copy for generation and compilation
to preserve any local LaTeX auxiliaries. Results are summarized in
[verification.json](verification.json).

```bash
python3 -m unittest discover -s processing/Processing/decomposition/tests -p test_audit_empirical_assets.py
python3 -m unittest writing.tests.test_package_submission_assets
python3 writing/make_appendix_assets.py
python3 processing/Processing/decomposition/validate_prose_provenance.py
(cd writing/submission_inversions_review/manuscript && latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error main_rw_again.tex)
pdftoppm -f 24 -l 28 -scale-to 1800 -png writing/submission_inversions_review/manuscript/main_rw_again.pdf /tmp/appendix-page
python3 writing/package_submission_assets.py
git diff --check
git diff --cached --check
```

- Reference-inventory tests: 5 passed; package tests: 6 passed.
- Appendix generation: five outputs, 35 cabinet sets, 20 baseline intervals,
  three selected contribution cases, and successful label/clipping checks.
- Local provenance validation: 35 blocks, 353 fields, no row-number warnings.
- Build: 28 pages; zero missing inputs, undefined references, unresolved
  citations or `??` markers. Table 5 resolves on page 25 and Table 6 on page 27.
  Pages 24–28 were rendered and inspected without clipping, overlap, illegible
  text or broken layout.
- Packages: 9 figures, 6 tables, and 18 files in each manuscript archive.
  Every member matches its current source file; both manuscript archives have
  identical contents, including the current TeX and PDF. Referenced image paths
  are preserved. The script verifies membership and contents during execution
  and creates no persistent publication byte manifest.

## Remaining limitation

Full-manuscript provenance validation still needs the local untracked files
`generated/cabinet_party_sets/{cabinet_party_sets,occurrences,summary}.csv`.
They are not required for appendix generation, LaTeX compilation or packaging.
Rebuilding that cabinet pipeline is outside this cleanup.
