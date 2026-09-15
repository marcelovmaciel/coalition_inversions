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
national denominator. Observed cabinet construction uses the pinned contemporaneous-affiliation release described below.

## Main Workflow

Run commands from the repository root unless the command changes directory.
The complete production workflow, including both universes, exact accounting,
figures, independent audits, and `main_rw_again.pdf`, is:

```bash
JULIA_BIN=processing/julia_paper_runtime.sh processing/rebuild_manuscript.sh
```

The normal build validates the revised literal prose and its numerical provenance,
compiles both PDFs, and creates the submission and cabinet party-set handoffs.
`--freeze-prose` is a diagnostic compatibility option, not a completed submission build.
The cabinet stage verifies the immutable V6 release pin, translates daily memberships,
retains consecutive periods for chronology, and groups distinct translated memberships
across the full election window. It never invokes the historical builder. Set `PYTHON_BIN`
or `JULIA_BIN` to select a runtime. For the exact existing numerical baseline,
use Julia 1.12.7 with `-Cgeneric --compiled-modules=no --pkgimages=no --threads=1
--gcthreads=1` (the repository wrapper above supplies those flags; set `JULIA_PAPER_EXECUTABLE` if installed elsewhere). An overwrite rebuild
preserves existing WIP; `--clean` remains available only for generated analysis trees.
The equivalent individual stages are listed below.

1. Install Julia dependencies.

```bash
julia --project=processing/Processing -e 'using Pkg; Pkg.instantiate()'
```

2. Prepare the registry and run the analysis using the documented Julia runtime.

```bash
python3 processing/cabinet_v5.py prepare
ALLOW_OVERWRITE=true SYNC_REVIEW_ASSETS=true processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/running/running.jl
ALLOW_OVERWRITE=true SYNC_REVIEW_ASSETS=true processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/decomposition/run_decomposition.jl
python3 processing/cabinet_v5.py analyze
python3 processing/cabinet_party_sets.py
python3 processing/cabinet_v5_assets.py
```

This writes the paper analysis artifacts under:

```text
processing/Processing/output/paper/
```

3. Generate all manuscript figures, including the separately rendered party
representation profile.

```bash
processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/make_representation_profile.jl
python writing/make_coalition_figures.py --artifact-root processing/Processing/output/paper --figure-dir writing/submission_inversions_review/manuscript
python3 writing/make_appendix_assets.py
```

This writes figure PDFs under:

```text
writing/submission_inversions_review/manuscript/
```

The figure runner also regenerates `cross_domain_components.pdf` from the
audited cabinet and ideological registries under `output/paper/` and exact
party/district accounting under the sibling `output/decomposition/` directory.
The shared extractor is `processing/Processing/decomposition/cross_domain_components.py`;
manuscript production does not require the exploratory report.

4. Compile the manuscript.

```bash
cd writing/submission_inversions_review/manuscript
latexmk -pdf -interaction=nonstopmode main_rw_again.tex
```

The compiled manuscript is:

```text
writing/submission_inversions_review/manuscript/main_rw_again.pdf
```

The source at `writing/submission_inversions_review/manuscript/main_rw_again.tex` is the
authoritative current manuscript. `writing/main.tex` is retained only as a
legacy draft and should not be used to build the submission.

The decomposition rebuild also produces permanent party-size/cabinet
accounting diagnostics. The existing party accounting panel gains normalized
A/B components and cabinet participation counts/days. Descriptive summaries,
distinct-set decompositions, and links to dated cabinet
occurrences are documented in
[`processing/Processing/decomposition/report/README.md`](processing/Processing/decomposition/report/README.md#permanent-party-size-and-cabinet-diagnostics).
The shared cabinet set registry now also supplies all manuscript cabinet tables
and figures; the additional party-size diagnostics enter the central accounting report. The 5% national-vote benchmark is descriptive only.

## Data Inputs

The replication workflow uses these input locations:

```text
data/raw/electionsBR/
cabinet_dataset/releases/2026-03-19-history-v6-onyx-candidate/
scrape_classification/output/classificacao_2023/
scrape_classification/output/classificacao_2025/
processing/Processing/data/
```

`data/raw/electionsBR/` contains the raw TSE election files used for votes and
seats.

`cabinet_dataset/releases/2026-03-19-history-v6-onyx-candidate/` contains normalized historical
daily primary sets, periods, memberships, witnesses, evidence, and explicit provisional assumptions.
The 4,096-day primary chronology retains 3,996 evidence-established and 100 historically unresolved days.
`processing/Processing/data/cabinet_release_pin.json` pins version and hashes;
`processing/cabinet_v5.py` validates the daily release and applies the unchanged audited election-party crosswalk before recompression;
`src/CabinetRelease.jl` validates the pin and provides the adapter to the existing Julia pipeline.
No live reconstruction or scraper runs during paper regeneration.

`scrape_classification/output/classificacao_2023/` and
`scrape_classification/output/classificacao_2025/` contain the party ideology
classification inputs used to construct the fixed election-year party orders.

`processing/Processing/data/` contains party harmonization inputs used by the
Julia runner.

## Software

The Julia project is defined by:

```text
processing/Processing/Project.toml
processing/Processing/Manifest.toml
```

Use Julia with the project environment shown in the workflow command.

The figure script requires Python with `numpy`, `pandas`, and `matplotlib`.

Manuscript compilation requires a LaTeX installation with `latexmk`.

## Checks

After running the main analysis, the high-level replication results should be:

The current V6 chronology contains 55 historical periods and 53 translated
analytical periods. These supply **35 distinct election-year cabinet party sets**:
12 for 2014, 18 for 2018, and 5 for 2022. **Two sets invert**, occupying **260 of
4,096 covered days** (5 for Dilma's 2014-election set and 255 for Lula's
2022-election set). Deduplication changes observation counts, never the
membership-determined electoral vector or inversion days. These invariants are
independently checked against the saved pre-migration working tree, with the documented Onyx-only correction on March 27–30, 2022. The preserved V5 release and all electoral inputs remain unchanged. See [historical audit](ONYX_MARCH_2022_AUDIT.md) and [propagation report](ONYX_PARTY_SET_PROPAGATION_REPORT.md).

The [current migration report](CABINET_PARTY_SET_MIGRATION_REPORT.md),
[canonical registry and linkage](generated/cabinet_party_sets/README.md), and
[compact upload handoff](handoff/cabinet_party_sets_handoff.zip) document the
production workflow. `cabinet_party_sets.py` defines identity from election year
and sorted translated membership. Its identity/temporal registry is shared by
Julia's verified set view; `PartySizeDiagnostics.jl` attaches exact accounting in
`output/decomposition/raw/cabinet_party_set_accounting.csv`. The copy in
`generated/cabinet_party_sets/cabinet_party_sets.csv` is a documented mirror.
Short labels are resolved by `label_lookup.csv`; stable IDs depend on membership,
not order, dates, administration, evidence status or numerical coordinates.

All cabinet comparisons use one electoral vector per set. Recurrent appearances
remain in `occurrences.csv`, `period_linkage.csv`, `provenance_intervals.csv` and
`daily_linkage.csv`. Dates use inclusive starts and exclusive ends. Durations
sum actual dates, never the span between the first and last appearance. Set
frequencies are unweighted descriptive counts, not independent observations or
formation probabilities. Provisional-only sets remain included; scenarios have
separate registries. Party participation distinguishes set counts from days.

`generated/cabinet_v5/` retains chronology, evidence and date-level sensitivities;
its current tables/figures are compatibility mirrors. The root V5 integration
report, Org modification map, and old handoff describe the earlier historical
integration and are preserved archives. The current prose is revised and
validated. The release pin remains `processing/Processing/data/cabinet_release_pin.json`;
no history builder or scraper runs. Independent rational party/district closure
and protected non-cabinet output/slice signatures are checked by
`processing/cabinet_v5_validation.py`; the unit migration is checked by
`processing/cabinet_party_set_validation.py`.

The generated [universe comparison](processing/Processing/output/paper/tables/ideological_universe_comparison.csv)
contains all twelve election/universe/k headline rows. Primary exact-connected
inversions occur in all three elections; the all-party robustness retains the
2018 exact-connected null. Thus the null is sensitive to whether zero-seat
parties determine parliamentary adjacency. The 2014 and 2022 strongest endpoint
regions survive, while member sets, vote shares, minimality, and decomposition
components can differ.

Use the files under `processing/Processing/output/paper/` to inspect the
generated tables and diagnostics.

The primary machine-readable files keep the existing `ideology_k_gap_*.csv`
names and carry `ideological_universe=seat_winning`. Matching
`*_all_parties.csv` files contain the robustness domain. Complete combined
outputs are:

- `raw/ideology_k_gap_accounting_both_universes.csv`: every admissible k=0/1
  coalition, its members, filtered and original span indices, gaps, observed
  seats, all-valid-vote share, q, d, R, A, B, inversion, and minimality.
- `raw/ideology_k_gap_party_contributions_both_universes.csv.gz`: every member's
  q, d, A, B, including exact rational values, linked to universe/election/k.
- `raw/ideology_k_gap_minimal_accounting_both_universes.csv`: complete minimal
  winning sets for both specifications.
- `tables/ideological_universe_comparison.csv`: headline counts and strongest
  cases, including endpoint-region sensitivity.
- `tables/table_appendix_cabinet_interval_bridge{,_all_parties}.csv`: separate
  closure, gap, and overlap calculations in each ideological universe. Primary
  overlaps compare represented cabinet members, while cabinet votes, seats,
  and observed composition retain their original definitions.
- `diagnostics/ideology_k_gap_checks.csv` and
  `diagnostics/ideological_universe_reproduction_audit.json`: fail-loud audits.

The primary decomposition is produced under `output/decomposition/`; the same
routines write all-party robustness under `output/decomposition/all_parties/`.
Manuscript-facing numerical tables and figure inputs are generated by the
production pipeline and synchronized into the manuscript directory. The main
summary (`table_03_ideology_exact_connected_summary.tex`) contains only the
exact-connected baseline, with one row per election. The manuscript now has two appendices: supporting coalition data and
robustness of the ideological coalition domain. `writing/make_appendix_assets.py`
reads existing authoritative CSV outputs and writes four manuscript-specific
compact tables and the two-panel `cabinet_membership_inversions.pdf`. It runs after
upstream asset synchronization in the production workflow. Full cabinet histories,
all baseline interval memberships, complete member/district decompositions,
closure/overlap diagnostics, and both original robustness tables remain generated
and available for replication. The compact inputs use separate filenames, so the
full outputs are never overwritten by this editorial export. Figure 3 and the
cabinet panels use the same seat-winning ordinal party orders.

To refresh only the appendix presentation from existing outputs (no new empirical
analysis), run `python3 writing/make_appendix_assets.py`, then the LaTeX command
above. The generator prints semantic validation outcomes; the concise verification
report is `writing/appendix_revision/verification.json`, and the dependency map is
in `writing/appendix_revision/CHANGELOG.md`. Rendered PDF metadata is not an
empirical acceptance criterion.

Run `python3 writing/package_submission_assets.py` to refresh the submission
archives from the current manuscript source, compiled PDF, bibliography and
referenced assets. The script requires only tracked publication inputs and
verifies exact archive membership and every member against its current file
during execution, including agreement between the two manuscript archives. It
does not create a persistent publication byte manifest. Full-manuscript provenance
validation is a separate task.

Appendix A.3 prints the two inverted cabinets and baseline MDB–UNIÃO from the
full `latex/table_coalition_party_component_extremes.tex` export. The decomposition runner
calls `party_component_extremes` and `party_component_extremes_latex` in
`decomposition/PartyComponentTable.jl` through `AccountingIntegration.jl`.
These rank the existing exact `A_i`/`B_i` fields in
`raw/coalition_party_contributions.csv` for all dynamically selected cabinet inversions and the seven
primary minimal exact-connected inversions selected by the `d_i` table.
The party-year source is `raw/party_accounting_all_years.csv`.
The generated table CSV retains the unrounded and exact extrema; the associated
`audit/coalition_party_component_checks.csv` checks member and coalition closure
before rounding. Outputs are mirrored from `output/decomposition/` to
`output/paper/`, and the LaTeX table is synchronized to the manuscript.

Run the independent serialized-output audit after decomposition:

```bash
python3 processing/audit_ideological_universes.py
```

## Manuscript numerical values

Ordinary prose in `writing/submission_inversions_review/manuscript/main_rw_again.tex`
uses literal values. Each migrated paragraph has one adjacent LaTeX comment block
that records its source CSVs, semantic row keys, unrounded fields, and displays.
Tables, figures, and structured appendices still come from the existing generators
and `\input` / graphics workflow. Notation and institutional constants retain
normal LaTeX macros.

```tex
% PROVENANCE-BEGIN descriptive-claim-id
% source: repository/relative/output.csv
% row:
%   key: election=2018; universe=seat_winning; k=0
%   row_at_generation: 2
%   fields:
%     source_column: raw value
%   display:
%     source_column: literal text in the paragraph
% PROVENANCE-END descriptive-claim-id
```

Repeat `row:` for distinct observations, or `source:` followed by its rows when a
paragraph cites more than one CSV. **Semantic keys must resolve uniquely.**
`row_at_generation` counts **1-based data rows, excluding the header**; it is only
a navigation hint. Reordering a CSV produces warnings and updated audit row
numbers, not a validation failure. Every field must still agree with its keyed
observation. Decimal-equivalent numeric strings are accepted without a rounding
tolerance; other values and semantic keys use exact string matching. Optional
`display:` values must occur in the immediately preceding paragraph, allowing
whitespace changes. They do not perform natural-language parsing or infer a
rounding rule. `note:` is available for short clarifications.

Direct claims cite their existing production CSVs. Multi-row counts, extrema,
and means use `tables/prose_analysis_summaries.csv`, generated by
`decomposition/ProseSummaries.jl` from current output CSVs. Cabinet summaries use one observation per distinct election-year set;
party and ideological aggregation rules are preserved. The full summary key is
`summary; metric; aggregation; ideological_universe; k; election`, with an
unrounded `value`, upstream source, filter, and row count. Existing prose rows
remain uniquely selectable by `summary; metric; aggregation`. This CSV contains no macro names, display rules, or TeX.
It keeps provenance for aggregates compact without re-enumerating coalitions or
recomputing electoral analysis. The old per-macro registry, TeX output, and
prose injection writer have been removed.

Component comparisons use `summary=ideology-component-dominance`,
`ideological_universe=seat_winning/all_parties`, `k=0/1`, and
`election=all/2014/2018/2022`. Metrics `A_C_gt_B_C`, `A_C_lt_B_C`, and
`A_C_eq_B_C` each have `aggregation=count` and `aggregation=percentage` rows;
`metric=minimal_inversions; aggregation=count` records the denominator, also
stored in `source_row_count`. Selection requires both
`minimal_seat_majority=true` and `inversion=true` in the authoritative combined
accounting CSV. Comparisons use unrounded stored values with strict equality;
the `1e-10` absolute accounting-identity tolerance does not define ties. Empty
inversion sets have zero counts and `value=missing` percentages. Generation
checks accounting identities, domain-summary denominators, the comparison
partition, and the primary k=1 total of 100 (46/42/12).

To refresh only these summaries and their artifact-manifest entries from
existing outputs, without regenerating analysis or manuscript assets:

```bash
julia --startup-file=no --project=processing/Processing processing/Processing/decomposition/ProseSummaries.jl --refresh
```

`processing/rebuild_manuscript.sh` regenerates outputs and summaries, compiles
both PDFs, then runs `decomposition/audit_empirical_assets.py` before packaging.
That final audit validates local prose provenance and writes current CSV row
numbers to `output/decomposition/audit/manuscript_prose_provenance.csv`.
The manuscript asset inventory, `manuscript_empirical_asset_manifest.csv`, records
only `reference_source`, `reference_kind` and `target`; missing referenced files
fail the audit. The separate paper-output audit retains its empirical hashes.
A changed CSV value fails provenance validation; update the literal claim and its
comment together after review.
The recorded baseline uses Julia 1.12.7 with generic CPU code, compiled modules
and package images disabled, and one Julia/GC thread. Use the existing
`JULIA_BIN` override to reproduce that runtime; even last-digit raw drift from a
different runtime is reported rather than hidden by a tolerance.

Run focused checks without rerunning the analysis:

```bash
python3 processing/Processing/decomposition/validate_prose_provenance.py
python3 processing/Processing/decomposition/audit_empirical_assets.py
python3 -m unittest discover -s processing/Processing/decomposition/tests -v
processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/decomposition/test_prose_summaries.jl
```

The [migration audit](processing/Processing/decomposition/MANUSCRIPT_VALUE_MIGRATION.md)
and [complete historical macro inventory](processing/Processing/decomposition/PROSE_MACRO_INVENTORY.csv)
record every retired macro's source, semantic observations, row numbers, raw
fields, formatting rule, former definition/writer, usage, and replacement source.
The inventory is an audit record; no production code reads it.

## Tests

Cabinet chronology still combines adjacent periods only when translated
memberships match. The primary analytical registry additionally deduplicates
nonconsecutive appearances within election. Original periods and dates remain
linked, with evidence status and actual days. Independent tests check stable
membership IDs under input permutations, period-splitting invariance, evidence
and scenario separation, unique contributions/figure rows, exact accounting and
unchanged primary dates and ideological outputs.

```bash
python3 -m unittest discover -s processing/tests -p test_cabinet_party_sets.py -v
python3 processing/cabinet_party_set_validation.py
```

Run its regression checks after generating the analysis outputs:

```bash
processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/test/test_cabinet_period_coalescing.jl
```

Run the focused decomposition suite from the repository root:

```bash
processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/decomposition/runtests.jl
```

Run the focused ideological-domain suite with:

    processing/julia_paper_runtime.sh -O0 --startup-file=no --project=processing/Processing processing/Processing/test/test_ideological_interval_coalitions.jl

This focused suite is the empirical gate for the decomposition and checks the
current identified-case registry, coalition compositions, district accounting identities, and
party contribution identities against the pinned contemporaneous release. The focused ideological suite includes synthetic adjacency/denominator tests
and checks both empirical universes. The full Julia suite is run with the
repository project environment; the figure and decomposition suites validate
generated registries and accounting identities.
