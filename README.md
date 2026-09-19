# Coalition Inversions

Analysis and replication files for *Seat Majorities without Vote Majorities:
Coalition Inversions in Brazil's Chamber of Deputies*. The paper examines when
party coalitions hold a seat majority without a national vote majority, using
observed cabinet party sets and ideologically ordered coalitions for the 2014,
2018, and 2022 elections.

## Data

The analysis uses federal-deputy candidate, party-vote, and seat data in
`data/raw/electionsBR/`, together with party identity and lineage tables.
[data/frozen_electoral_inputs.json](data/frozen_electoral_inputs.json) identifies
and pins these inputs. The ideological ordering and classification come from
the retained 2023 and 2025 tables under `scrape_classification/output/`.

Cabinet membership comes from the `2026-03-19-v6-election-v1` release produced by
`cabinet_compositions`. Its four-file contract—primary periods, sensitivity
periods, coverage, and metadata—is copied into `data/cabinet/` and pinned by
[data/cabinet_release.json](data/cabinet_release.json).
Cabinet reconstruction is not performed here.

## Running the analysis

Run commands from the repository root with GNU Make, Julia, Python, and LaTeX
available. Python needs NumPy, pandas, Matplotlib, and Pillow; manuscript
compilation uses `latexmk` and Biber.

The Julia runtime is specified in
[processing/julia_paper_runtime.sh](processing/julia_paper_runtime.sh), with
package versions in [Project.toml](processing/Processing/Project.toml) and
[Manifest.toml](processing/Processing/Manifest.toml). Python dependencies do not
have a complete lockfile. Set `PYTHON_BIN` or `JULIA_BIN` when using a different
executable; `JULIA_PAPER_EXECUTABLE` selects the Julia binary used by the wrapper.
Dependencies must already be installed. Git LFS is needed to retrieve the large
electoral input files.

```bash
make test        # Rebuild the analysis and run the regular scientific tests
make test-deep   # Include regular tests, exhaustive checks, and a fresh replication run
make paper       # Rebuild results, figures, tables, and the manuscript PDF
make package     # Package the compiled manuscript and its referenced assets
make replication # Package the frozen inputs, code, tests, and manuscript sources
```

`make test-deep` includes `make test`. `make paper` runs all steps needed for the
PDF. Run `make package` after `make paper`; it packages the existing build.
`make replication` creates a source archive without requiring a compiled paper.
For a prose-only manuscript edit, `make compile` recompiles using existing assets.

## Outputs

Generated files are written under `build/`:

- `build/results/`: scientific results and summaries.
- `build/assets/`: figures and LaTeX table fragments.
- `build/manuscript/main_rw_again.pdf`: manuscript PDF.
- `build/submission/publication.zip`: manuscript submission package.
- `build/submission/replication.zip`: inputs and sources for replication.

These build products are ignored by Git. `make clean` removes `build/`.

## Repository relationship

`cabinet_compositions` produces the cabinet release; this repository treats its
pinned copy as a frozen scientific input. Running the analysis does not require
a checkout of the producer repository.
