#!/usr/bin/env julia
# Read-only adapter: reuse the authoritative raw-data loaders; write only the
# explicitly supplied diagnostic panel, never paper or manuscript assets.
using CSV
using DataFrames
using Processing

include(joinpath(@__DIR__, "CoalitionDecomposition.jl"))
using .CoalitionDecomposition

length(ARGS) == 1 || error("Usage: export_party_AB_panel.jl OUTPUT.csv")
root = normpath(joinpath(@__DIR__, "..", "..", ".."))
baseline = CSV.read(joinpath(root, "build", "results", "domains",
                             "raw", "party_seat_differentials_all_years.csv"), DataFrame)
panels = DataFrame[]
for year in (2014, 2018, 2022)
    national = baseline[baseline.election_year .== year, :]
    totals = unique(national.national_vote_total)
    length(totals) == 1 || error("$(year): inconsistent national denominators")
    inputs = joinpath(root, "data", "raw", "electionsBR", string(year))
    accounting = build_year_accounting(
        year, joinpath(inputs, "party_mun_zone.csv"), joinpath(inputs, "candidate.csv");
        apportionment_path = joinpath(inputs, "seats.csv"),
        expected_national_votes = only(totals),
    )
    CoalitionDecomposition.validate_party_baseline!(accounting, baseline)
    panel = select(accounting.panel, :district, :party, :votes, :seats,
                   :district_votes, :district_seats)
    insertcols!(panel, 1, :election => fill(year, nrow(panel)))
    push!(panels, panel)
    println("Rebuilt and validated $(year): $(nrow(accounting.party)) parties, ",
            "$(accounting.national_votes) votes, $(accounting.national_seats) seats")
    flush(stdout)
end
CSV.write(only(ARGS), vcat(panels...))
