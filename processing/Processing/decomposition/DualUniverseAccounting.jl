module DualUniverseAccounting

using CSV
using DataFrames
using SHA
using JSON3
import ..AccountingEvidence
import ..AccountingIntegration

"""Generate robustness accounting and complete k-domain exports through shared routines.

The complete national accounting panels are shared. Only the ideological
registry supplied to the existing decomposition functions changes.
"""
function write_dual_universe_outputs(paper_root, output_root, coalition_periods, accounting_by_year)
    path = joinpath(paper_root, "raw", "ideological_interval_metrics_all_parties.csv")
    intervals = CSV.read(path, DataFrame)
    all(String.(intervals.ideological_universe) .== "all_parties") || error("Robustness registry universe mismatch.")
    registry = AccountingEvidence.build_inversion_case_registry(
        coalition_periods, intervals, accounting_by_year,
    )
    integration = AccountingIntegration.build_accounting_integration(registry, accounting_by_year)
    robustness_root = joinpath(output_root, "all_parties")
    artifacts = AccountingIntegration.write_accounting_integration_outputs(robustness_root, integration)
    records = [merge(row, (path = "all_parties/" * row.path,)) for row in artifacts]
    python = get(ENV, "PYTHON", "python3")
    script = joinpath(@__DIR__, "cross_domain_components.py")
    run(`$python $script $paper_root --decomposition-root $output_root`)
    paper_records = NamedTuple[]
    for relative in (
        "raw/ideology_k_gap_accounting_both_universes.csv",
        "raw/ideology_k_gap_minimal_accounting_both_universes.csv",
        "figure_data/cross_domain_components.csv",
    )
        file = CSV.File(joinpath(paper_root, relative))
        push!(paper_records, (path = relative, artifact_type = first(split(relative, '/')),
            description = "Exact-audited ideological accounting with explicit party universe and all-valid-vote denominator.",
            rows = length(file), columns = length(propertynames(file))))
    end
    accounting_audit = JSON3.read(read(joinpath(paper_root, "diagnostics/ideological_accounting_both_universes.json"), String))
    push!(paper_records, (path = "raw/ideology_k_gap_party_contributions_both_universes.csv.gz",
        artifact_type = "raw", description = "Complete exact member-party vectors for both ideological universes (deterministic gzip CSV).",
        rows = Int(accounting_audit.member_rows), columns = Int(accounting_audit.member_columns)))
    push!(paper_records, (path = "diagnostics/ideological_accounting_both_universes.json",
        artifact_type = "diagnostic", description = "Both-universe exact accounting and domain-relative minimality audit.",
        rows = 1, columns = 1))
    return records, DataFrame(paper_records)
end

end
