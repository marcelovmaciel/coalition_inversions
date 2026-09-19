using Test, CSV, DataFrames, Processing
using .CoalitionDecomposition
chronology_periods=evidence_csv("raw/coalition_period_quantities.csv")
coalition_periods=Processing.cabinet_set_view(chronology_periods)

@testset "Shared set view rejects changed recurrent electoral vectors" begin
    @test nrow(coalition_periods) == 35 # Independently audited V6: 12 + 18 + 5 memberships.
    @test allunique(coalition_periods.coalition_id)
    @test sum(coalition_periods.days_overlapping_mandate) == sum(chronology_periods.days_overlapping_mandate) == 4096
    @test isequal(Processing.cabinet_set_view(chronology_periods[end:-1:1,:]), coalition_periods)
    repeated = first(filter(r -> r.analytical_period_count > 1, eachrow(Processing.cabinet_set_identity())))
    labels = split(repeated.analytical_period_labels, ';')
    i = findfirst(==(labels[1]), chronology_periods.cabinet_period)
    for column in (:v_C, :s_C, :q_C, :d_C, :R_C)
        broken = deepcopy(chronology_periods)
        broken[i, column] += 1
        @test_throws r"electoral vector differs" Processing.cabinet_set_view(broken)
    end
end

@testset "Empty inversion selections retain complete CSV schemas" begin
    empty_periods = coalition_periods[1:0, :]
    result = CoalitionDecomposition.decompose_inversions(empty_periods, Dict())
    @test isempty(result.decomposition)
    @test :coalition_id in propertynames(result.decomposition)
    @test :component in propertynames(result.component_figure_data)
end

@testset "CSV cabinet identity and empty-set parsing" begin
    parsed = CSV.read(IOBuffer("period,cabinet_period\n2015.1,2015.1\n2015.10,2015.10\n"), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    @test parsed.period == ["2015.1", "2015.10"]
    @test parsed.cabinet_period == ["2015.1", "2015.10"]
    @test CoalitionDecomposition.split_parties(missing) == String[]
    @test CoalitionDecomposition.split_parties("") == String[]
end
