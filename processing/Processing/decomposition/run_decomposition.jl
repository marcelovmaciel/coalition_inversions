#!/usr/bin/env julia

using Pkg

const DECOMPOSITION_DIR = @__DIR__
const PROCESSING_ROOT = normpath(joinpath(DECOMPOSITION_DIR, ".."))
const REPO_ROOT = normpath(joinpath(PROCESSING_ROOT, "..", ".."))

Pkg.activate(PROCESSING_ROOT)

using CSV
using DataFrames
using SHA
using Processing

include(joinpath(DECOMPOSITION_DIR, "CoalitionDecomposition.jl"))
using .CoalitionDecomposition
include(joinpath(DECOMPOSITION_DIR, "AccountingEvidence.jl"))
using .AccountingEvidence
include(joinpath(DECOMPOSITION_DIR, "AccountingIntegration.jl"))
using .AccountingIntegration
include(joinpath(DECOMPOSITION_DIR, "DualUniverseAccounting.jl"))
include(joinpath(DECOMPOSITION_DIR, "ProseSummaries.jl"))
using .ProseSummaries

const PAPER_ROOT = joinpath(REPO_ROOT, "build", "results", "domains")
const OUTPUT_ROOT = joinpath(REPO_ROOT, "build", "results", "accounting")
const DATA_ROOT = joinpath(REPO_ROOT, "data", "raw", "electionsBR")
const ALLOW_OVERWRITE = lowercase(get(ENV, "ALLOW_OVERWRITE", "false")) in
    ("1", "true", "yes")
const EXPECTED_NATIONAL_VOTES = Dict(
    2014 => 97_355_354,
    2018 => 98_264_190,
    2022 => 109_413_508,
)

ALLOW_OVERWRITE || error(
    "The decomposition rebuild overwrites generated artifacts. Set ALLOW_OVERWRITE=true.",
)

function sha256_file(path::AbstractString)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end

function require_file(path::AbstractString)
    isfile(path) || error("Required corrected-baseline input is missing: $(path)")
    return path
end

function append_output_manifest_rows!(rows::AbstractVector{<:NamedTuple})
    manifest_path = joinpath(OUTPUT_ROOT, "artifact_manifest.csv")
    manifest = CSV.read(manifest_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    paths = Set(String.(getfield.(rows, :path)))
    filter!(row -> !(String(row.path) in paths), manifest)
    for row in rows
        push!(manifest, row)
    end
    sort!(manifest, :path)
    CSV.write(manifest_path, manifest)
    return manifest
end

println("Coalition decomposition rebuild")
println("Julia version: ", VERSION)
println("Processing root: ", PROCESSING_ROOT)
println("Output root: ", OUTPUT_ROOT)
println("ACCOUNTING_ATOL: ", ACCOUNTING_ATOL)
println("ACCOUNTING_RTOL: ", ACCOUNTING_RTOL)

observed_path = require_file(joinpath(PAPER_ROOT, "raw", "cabinet_coalition_metrics.csv"))
party_path = require_file(joinpath(PAPER_ROOT, "raw", "party_seat_differentials_all_years.csv"))
ideology_input_path = require_file(joinpath(PAPER_ROOT, "raw", "ideological_interval_metrics.csv"))
observed = CSV.read(observed_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
party_baseline = CSV.read(party_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
ideological_intervals = CSV.read(ideology_input_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)

accounting_by_year = Dict{Int,Any}()
for year in sort(collect(keys(EXPECTED_NATIONAL_VOTES)))
    vote_path = require_file(joinpath(DATA_ROOT, string(year), "party_mun_zone.csv"))
    candidate_path = require_file(joinpath(DATA_ROOT, string(year), "candidate.csv"))
    apportionment_path = require_file(joinpath(DATA_ROOT, string(year), "seats.csv"))
    accounting_by_year[year] = build_year_accounting(
        year,
        vote_path,
        candidate_path;
        apportionment_path = apportionment_path,
        expected_national_votes = EXPECTED_NATIONAL_VOTES[year],
    )
end

coalition_periods = recompute_coalition_periods(
    observed,
    accounting_by_year;
    party_baseline = party_baseline,
)
chronology_periods = coalition_periods
coalition_sets = Processing.cabinet_set_view(chronology_periods)

outputs = decompose_inversions(coalition_sets, accounting_by_year)
full_accounting = build_full_accounting_outputs(accounting_by_year)
party_size_diagnostics = build_party_size_diagnostics!(
    full_accounting.parties, coalition_periods, accounting_by_year,
)
manifest = write_decomposition_outputs(OUTPUT_ROOT, coalition_periods, outputs)

ideological_regression = validate_ideological_counts(ideological_intervals)
ideological_audit_path = joinpath(OUTPUT_ROOT, "audit", "ideological_regression.csv")
CSV.write(ideological_audit_path, ideological_regression)
case_registry = build_inversion_case_registry(
    coalition_sets,
    ideological_intervals,
    accounting_by_year,
)
accounting_integration = build_accounting_integration(case_registry, accounting_by_year)
integration_artifacts = write_accounting_integration_outputs(OUTPUT_ROOT, accounting_integration)
party_size_artifacts = write_party_size_diagnostic_outputs(
    OUTPUT_ROOT, full_accounting, party_size_diagnostics,
)

# Complete member/district vectors for every registered cabinet set, unweighted.
all_set_vectors = decompose_inversions(coalition_sets, accounting_by_year; inversions_only=false)
for (name,frame) in (("party",all_set_vectors.party_contributions),("district",all_set_vectors.district_contributions))
    frame[!, :cabinet_party_set_id] = frame.coalition_id
    relative = "raw/cabinet_party_set_$(name)_contributions.csv"
    path = joinpath(OUTPUT_ROOT,relative)
    CSV.write(path,frame)
    push!(party_size_artifacts,(path=relative,artifact_type="raw",description="One cabinet-set/member or cabinet-set/district vector; occurrence linkage is separate.",rows=nrow(frame),columns=ncol(frame),sha256=sha256_file(path)))
end

# One exact national result per member set, shared by both domains and all
# published finite cabinet calendars. Consumers join their domain identities.
canonical_relative = "raw/coalition_accounting.csv.gz"
canonical_path = joinpath(OUTPUT_ROOT, canonical_relative)
canonical_accounting = write_coalition_accounting(canonical_path,
    joinpath(PAPER_ROOT, "raw", "ideology_k_gap_coalitions_both_universes.csv"),
    joinpath(REPO_ROOT, "data", "cabinet"), accounting_by_year)
push!(party_size_artifacts, (path=canonical_relative, artifact_type="raw",
    description="Canonical exact coalition quantities keyed by election and membership; domains and calendars join this table.",
    rows=nrow(canonical_accounting), columns=ncol(canonical_accounting), sha256=sha256_file(canonical_path)))

robustness_artifacts, dual_universe_paper_artifacts = DualUniverseAccounting.write_dual_universe_outputs(
    PAPER_ROOT, OUTPUT_ROOT, coalition_sets, accounting_by_year,
)


# Reuse the loaded exact accounting panels for every standalone diagnostic
# report output. This keeps the main rebuild complete without rereading TSE
# inputs or repeating the both-universe enumeration/export stage.
report_cases = decompose_case_registry(case_registry, accounting_by_year)
report_rankings = build_case_rankings(report_cases)
report_manifest = write_accounting_evidence_outputs(
    OUTPUT_ROOT, full_accounting, case_registry, report_cases, report_rankings;
    party_size_diagnostics = party_size_diagnostics,
    party_size_artifacts = party_size_artifacts,
)


prose_summary_artifacts = write_prose_summaries(OUTPUT_ROOT; paper_root = PAPER_ROOT)

manifest = append_output_manifest_rows!(vcat(integration_artifacts, party_size_artifacts, robustness_artifacts, prose_summary_artifacts, [
    (
        path = "audit/ideological_regression.csv",
        artifact_type = "audit",
        description = "Ideological inversion-count regression after the decomposition rebuild.",
        rows = nrow(ideological_regression),
        columns = length(names(ideological_regression)),
        sha256 = sha256_file(ideological_audit_path),
    ),
]))

# Register only tables actually produced here; no result or presentation mirrors.
paper_manifest = CSV.read(joinpath(PAPER_ROOT, "artifact_manifest.csv"), DataFrame)
append!(paper_manifest, dual_universe_paper_artifacts)
CSV.write(joinpath(PAPER_ROOT, "artifact_manifest.csv"), paper_manifest)

println("Recovered inversion cases:")
for row in eachrow(outputs.decomposition)
    println(
        "- $(row.coalition_id): q_C=$(row.q_C), d_C=$(row.d_C), r_C=$(row.r_C), " *
        "A_C=$(row.A_C), B_C=$(row.B_C)",
    )
end
println("Ideological regression:")
show(stdout, MIME("text/plain"), ideological_regression; allrows = true, allcols = true)
println()
println("Generated accounting-integration artifacts: ", length(integration_artifacts))
println("Party-size diagnostics: ", nrow(party_size_diagnostics.parties), " party-elections; ",
    nrow(party_size_diagnostics.period_linkage), " unchanged cabinet observations; ",
    nrow(party_size_diagnostics.cabinet_sets), " distinct translated sets.")
println("Focal accounting vectors: ", nrow(accounting_integration.focal.total))
println("Generated decomposition artifacts: ", nrow(manifest))

