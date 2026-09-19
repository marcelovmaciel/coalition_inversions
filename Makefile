# Current manuscript, independent scientific tests, and explicit packages.
.DEFAULT_GOAL := paper
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
PYTHON_BIN ?= python3
JULIA_BIN ?= processing/julia_paper_runtime.sh
JULIA = $(JULIA_BIN) -O0 --startup-file=no --project=processing/Processing
export PYTHON := $(PYTHON_BIN)
export PYTHONDONTWRITEBYTECODE := 1
export ALLOW_OVERWRITE := true
export MPLBACKEND := Agg
export JULIA_PKG_OFFLINE := true
export JULIA_PKG_PRECOMPILE_AUTO := 0
export JULIA_DEPOT_PATH := $(CURDIR)/build/cache/julia:$(HOME)/.julia
export MPLCONFIGDIR := $(CURDIR)/build/cache/matplotlib
export XDG_CACHE_HOME := $(CURDIR)/build/cache/xdg
export TMPDIR := $(CURDIR)/build/cache/tmp
export TEXMFVAR := $(CURDIR)/build/cache/texmf-var
export TEXMFCONFIG := $(CURDIR)/build/cache/texmf-config

.PHONY: paper analysis results figures tables compile test test-deep package replication clean cache
paper:
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove build/assets build/manuscript/main_rw_again.pdf
	$(MAKE) analysis results figures tables compile

cache:
	mkdir -p build/cache/{julia,matplotlib,xdg,tmp,texmf-var,texmf-config}

analysis: cache
	$(PYTHON_BIN) -B scripts/check_inputs.py
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove build/results
	$(PYTHON_BIN) -B processing/cabinet_v5.py prepare
	$(JULIA) processing/Processing/running/running.jl
	$(JULIA) processing/Processing/decomposition/run_decomposition.jl
	$(PYTHON_BIN) -B processing/cabinet_v5.py analyze
	$(PYTHON_BIN) -B processing/cabinet_party_sets.py

results: cache
	$(PYTHON_BIN) -B processing/Processing/decomposition/manuscript_results.py

figures: cache
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove $(wildcard build/assets/*.pdf build/assets/*.png)
	$(JULIA) scripts/make_representation_profile.jl
	$(PYTHON_BIN) -B scripts/make_figures.py

tables: cache
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove $(wildcard build/assets/*.tex)
	$(PYTHON_BIN) -B scripts/make_tables.py

compile: cache
	$(PYTHON_BIN) -B processing/Processing/decomposition/validate_prose_provenance.py
	$(PYTHON_BIN) -B scripts/package.py check
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove build/manuscript/main_rw_again.pdf
	mkdir -p build/manuscript
	latexmk -cd -pdf -interaction=nonstopmode -halt-on-error -auxdir=../../../build/manuscript -outdir=../../../build/manuscript writing/submission_inversions_review/manuscript/main_rw_again.tex || { rm -f build/manuscript/main_rw_again.pdf; exit 1; }

# Normal tests reconstruct scientific inputs; no pre-existing build is required.
test: cache
	$(MAKE) analysis results
	$(JULIA) processing/Processing/test/runtests.jl
	$(PYTHON_BIN) -B -m unittest discover -s processing/tests -v
	$(PYTHON_BIN) -B -m unittest discover -s processing/Processing/decomposition/tests -p test_prose_provenance.py -v
	$(PYTHON_BIN) -B -m unittest discover -s writing/tests -v
	$(PYTHON_BIN) -B processing/Processing/decomposition/validate_prose_provenance.py --direct-sources

# Adds exhaustive full-domain/member reconstruction and retained independent A/B evidence.
# `make test test-deep` shares the normal prerequisite within the same invocation.
test-deep: test
	$(PYTHON_BIN) -B -m unittest discover -s processing/Processing/decomposition/tests -p test_cross_domain_components.py -v
	$(PYTHON_BIN) -B processing/Processing/decomposition/party_AB_diagnostic.py
	$(PYTHON_BIN) -B writing/tests/deep_replication.py

package: cache
	$(PYTHON_BIN) -B scripts/package.py publication

replication: cache
	$(PYTHON_BIN) -B scripts/package.py replication

clean:
	$(PYTHON_BIN) -B scripts/check_inputs.py --remove build
