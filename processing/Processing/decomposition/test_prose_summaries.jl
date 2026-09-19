using Test, CSV, DataFrames
include(joinpath(@__DIR__, "ProseSummaries.jl"))
using .ProseSummaries
const PS_PAPER = normpath(joinpath(@__DIR__, "..", "..", "..", "build", "results", "domains"))
const PS_ACCOUNTING = normpath(joinpath(@__DIR__, "..", "..", "..", "build", "results", "accounting"))

@testset "Raw summaries preserve aggregations and semantic identity" begin
    sources = load_summary_sources(PS_PAPER, PS_ACCOUNTING)
    data = build_summaries(sources)
    reordered = build_summaries(Dict(key => rows[nrow(rows):-1:1, :] for (key, rows) in sources))
    @test isequal(data, reordered)
    @test allunique(select(data, ProseSummaries.SUMMARY_KEY))
    value(summary, metric, op) = parse(Float64, only(filter(r -> r.summary == summary &&
        r.metric == metric && r.aggregation == op, data).value))
    @test value("cabinet-party-sets", "count", "sum") == nrow(sources["sets"])
    @test value("cabinet-party-sets", "d_C", "count_positive") == count(>(0), sources["sets"].d_C)
    @test value("cabinet-component-signs", "A_C", "count_positive") == count(>(0), sources["sets"].A_C)
    @test value("seat-winning-k1-negative-within", "A_C", "count_negative") == 3
    @test value("district-magnitude", "S_d", "median") == 10
    @test value("district-magnitude", "S_d", "mean") == 19
    empty = copy(sources); empty["sets"] = sources["sets"][1:0, :]
    empty_result = build_summaries(empty)
    @test only(filter(r -> r.summary == "cabinet-party-sets" && r.metric == "count", empty_result).value) == "0"
    @test_throws ErrorException build_summaries(sources; specs = [SUMMARY_SPECS[1], SUMMARY_SPECS[1]])
    mktempdir() do temp
        # Use the existing source CSVs, then check serialization without TeX.
        rows = build_summaries(sources)
        path = joinpath(temp, "summaries.csv")
        CSV.write(path, rows)
        @test CSV.read(path, DataFrame; types = Dict(:value => String)) == rows
    end
end

@testset "Dominance audits reject corrupt accounting and denominators" begin
    sources = load_summary_sources(PS_PAPER, PS_ACCOUNTING)
    i = findfirst(r -> r.ideological_universe == "seat_winning" && r.k == 1 && r.minimal_inversion,
        eachrow(sources["ideology"]))
    for column in (:d_C, :A_C, :B_C)
        bad = deepcopy(sources)
        bad["ideology"][i, column] += 1e-5
        @test_throws r"accounting identity" audit_component_dominance(bad)
    end
    bad = deepcopy(sources); bad["ideology"][i, :A_C] = NaN
    @test_throws r"Nonfinite" audit_component_dominance(bad)
    bad = deepcopy(sources); bad["ideology"][i, :minimal_inversion] = false
    @test_throws r"conjunction" audit_component_dominance(bad)
    bad = deepcopy(sources); bad["summary"][1, :minimal_inversions] += 1
    @test_throws r"denominator disagrees" audit_component_dominance(bad)
    bad = deepcopy(sources); push!(bad["ideology"], bad["ideology"][i, :])
    @test_throws r"Duplicate ideological coalition" audit_component_dominance(bad)
    # Even coordinated denominator drift must fail the explicitly requested 100/46/42/12 gate.
    bad = deepcopy(sources)
    row = bad["ideology"][i, :]
    row.inversion = row.minimal_inversion = false
    j = findfirst(r -> r.ideological_universe == "seat_winning" && r.k == 1 && r.election == row.election,
        eachrow(bad["summary"]))
    bad["summary"][j, :minimal_inversions] -= 1
    @test_throws r"Primary k=1 denominator regression" audit_component_dominance(bad)
end

@testset "Dominance uses strict full-precision comparisons, including real ties" begin
    sources = load_summary_sources(PS_PAPER, PS_ACCOUNTING)
    i = findfirst(r -> r.ideological_universe == "seat_winning" && r.k == 1 && r.minimal_inversion,
        eachrow(sources["ideology"]))
    row = sources["ideology"][i, :]
    half = row.d_C / 2
    @test 0 < nextfloat(half) - half < 1e-10
    specs = filter(s -> s.summary == "ideology-component-dominance" &&
        s.filters.ideological_universe == "seat_winning" && s.filters.k == "1" &&
        !hasproperty(s.filters, :election) && s.aggregation == :count && s.metric != :minimal_inversions, SUMMARY_SPECS)
    original = [parse(Int, r.value) for r in eachrow(build_summaries(sources; specs))]
    old_category = [row.A_C > row.B_C, row.A_C < row.B_C, row.A_C == row.B_C]
    for (A, B, category) in ((half, half, [0, 0, 1]), (nextfloat(half), half, [1, 0, 0]), (half, nextfloat(half), [0, 1, 0]))
        row.A_C, row.B_C = A, B
        result = build_summaries(sources; specs)
        @test parse.(Int, result.value) == original - old_category + category
        @test sum(parse.(Int, result.value)) == 100
    end
end
