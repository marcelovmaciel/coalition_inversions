# Coalition Inversions

This repository analyzes coalition inversions in elections to Brazil's Chamber
of Deputies. A coalition inversion occurs when a set of parties holds a
majority of seats while receiving less than a majority of the national vote.

The analysis measures party vote and seat representation, coalition vote and
seat totals, coalition inversions, ideologically structured coalition domains,
minimal connected winning coalitions, and the decomposition of coalition-level
vote-seat departures. Observed cabinet-party-set coalitions are included where
relevant.

## Data

Federal-deputy electoral data are stored under `data/raw/electionsBR/`. The
frozen file and hash manifest is
[data/frozen_electoral_inputs.json](data/frozen_electoral_inputs.json).
Party identity and lineage inputs are in
`processing/Processing/data/party_aliases.csv` and
`processing/Processing/data/party_lineage_events.csv`.

Ideological ordering and classification inputs are stored under
`scrape_classification/output/`. Versioned cabinet-party-set calendars used in
the observed-coalition analysis are stored under `data/cabinet/` and treated as
frozen analytical inputs published by
[`cabinet_compositions`](https://github.com/marcelovmaciel/cabinet_compositions).
That upstream repository owns cabinet-history reconstruction and validation;
this repository consumes its published release for the paper's analysis,
replication, manuscript-support, and verification workflows.

## Running the analysis

Run commands from the repository root. The analysis requires Python with
NumPy, pandas, Matplotlib, and Pillow; Julia 1.12.7 is selected by
`processing/julia_paper_runtime.sh`. Julia package versions are pinned in
[Project.toml](processing/Processing/Project.toml) and
[Manifest.toml](processing/Processing/Manifest.toml). The document build also
requires a LaTeX installation with `latexmk` and Biber. Python dependencies do
not have a complete lockfile. Git LFS is required for the electoral input
files.

```bash
make test
make test-deep
make paper
make compile
make package
make replication
make clean
```

`make test` runs the regular scientific test suite. `make test-deep` adds the
slower exhaustive checks. `make paper` rebuilds analysis outputs, figures,
tables, and compiles the document sources. `make compile` compiles the current
document sources using existing generated assets. `make package` creates the
current publication/output package, and `make replication` creates a
self-contained replication archive. `make clean` removes `build/`.

Set `PYTHON_BIN`, `JULIA_BIN`, or `JULIA_PAPER_EXECUTABLE` when the relevant
executable is installed under a different name or location.

## Outputs

Generated outputs are written under `build/` and are ignored by Git:

- `build/results/`: analysis results and summaries.
- `build/assets/`: figures and generated table fragments.
- `build/manuscript/`: compiled document and auxiliary files.
- `build/submission/`: publication and replication ZIP archives.
