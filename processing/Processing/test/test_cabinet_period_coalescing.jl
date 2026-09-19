using Test
using Processing
using CSV
using DataFrames
using Dates
using JSON3

@testset "Cabinet bridge does not infer transitions across unknown gaps" begin
    paper=joinpath(@__DIR__, "..", "..", "..", "build", "results", "domains")
    for suffix in ("", "_all_parties")
        bridge=CSV.read(joinpath(paper,"diagnostics","cabinet_interval_chronology$(suffix).csv"),DataFrame;types=Dict(:cabinet_period=>String))
        @test issorted(bridge.period_start)
        for i in 1:nrow(bridge)
            row=bridge[i,:]
            adjacent=i>1 && bridge.period_end[i-1]+Day(1)==row.period_start && bridge.administration_id[i-1]==row.administration_id
            @test (row.transition_status=="identified_adjacent")==adjacent
            if !adjacent
                @test ismissing(row.delta_cabinet_mean_ideology_value_unweighted)
                @test ismissing(row.delta_cabinet_mean_ideology_value_seat_weighted)
                @test ismissing(row.entered_ideology_summary) || isempty(row.entered_ideology_summary)
                @test ismissing(row.left_ideology_summary) || isempty(row.left_ideology_summary)
            end
        end
    end
end

@testset "Set bridges have one row per registry ID and no implied transitions" begin
    paper=joinpath(@__DIR__, "..", "..", "..", "build", "results", "domains")
    expected=Set(Processing.cabinet_set_identity().cabinet_party_set_id)
    for suffix in ("", "_all_parties")
        bridge=CSV.read(joinpath(paper,"tables","table_appendix_cabinet_interval_bridge$(suffix).csv"),DataFrame;types=Dict(:cabinet_period=>String))
        @test Set(bridge.cabinet_party_set_id)==expected
        @test allunique(bridge.cabinet_party_set_id)
        @test all(==("not_applicable_set"), bridge.transition_status)
        @test all(ismissing, bridge.delta_cabinet_mean_ideology_value_unweighted)
        @test all(ismissing, bridge.delta_cabinet_mean_ideology_value_seat_weighted)
    end
end
