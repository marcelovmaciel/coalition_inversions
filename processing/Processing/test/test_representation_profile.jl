using Test
using CSV
using DataFrames


if !isdefined(@__MODULE__, :Processing)
    include(joinpath(@__DIR__, "..", "src", "Processing.jl"))
end

const ProfileProcessing = Processing


function _toy_representation_profile_data()
    years = repeat([2014, 2018, 2022]; inner = 2)
    return DataFrame(
        election_year = years,
        party = repeat(["A", "B"], 3),
        votes = repeat([40, 60], 3),
        vote_share = repeat([0.4, 0.6], 3),
        seats = repeat([0, 513], 3),
        seat_share = repeat([0.0, 1.0], 3),
        quota = repeat([205.2, 307.8], 3),
        seat_diff = repeat([-205.2, 205.2], 3),
        representation_ratio = repeat([0.0, 513 / 307.8], 3),
    )
end


@testset "party representation profile" begin
    input = _toy_representation_profile_data()
    prepared = ProfileProcessing.prepare_representation_profile(input)

    @test nrow(prepared) == nrow(input) == 6
    @test prepared.vote_share_percent == repeat([40.0, 60.0], 3)
    @test prepared.representation_ratio == input.representation_ratio
    @test prepared.representation_ratio[1:2] ≈ [0.0, 1 / 0.6]
    wrong_ratio = copy(input)
    wrong_ratio.representation_ratio[2] += 0.01
    @test_throws ArgumentError ProfileProcessing.prepare_representation_profile(wrong_ratio)
    @test_throws ArgumentError ProfileProcessing.prepare_representation_profile(select(input, Not(:representation_ratio)))
    @test all(prepared.representation_ratio[prepared.seats .== 0] .== 0)

    invalid_vote_share = copy(input)
    invalid_vote_share.vote_share[1] = 0.0
    @test_throws ArgumentError ProfileProcessing.prepare_representation_profile(
        invalid_vote_share,
    )

    missing_year = input[input.election_year .!= 2022, :]
    @test_throws ArgumentError ProfileProcessing.prepare_representation_profile(missing_year)

end
