using Test
using DataFrames

@testset "Canonical coalition accounting" begin
    parties = DataFrame(SG_PARTIDO = ["A", "X", "B", "C"],
        valid_total = [24, 40, 25, 11], total_seats = [130, 0, 127, 256])
    summary = Processing.party_summary(select(parties, :SG_PARTIDO, :valid_total),
        select(parties, :SG_PARTIDO, :total_seats); expected_total_seats = 513)
    @test sum(summary.quota) ≈ 513
    @test sum(summary.seat_diff) ≈ 0 atol = 1e-12
    @test summary.seat_diff ≈ summary.total_seats .- summary.quota
    exact_party = [Processing.exact_accounting(row.valid_total, row.total_seats;
        national_vote_total = 100) for row in eachrow(parties)]
    @test sum(p.q for p in exact_party) == 513
    @test sum(p.d for p in exact_party) == 0
    @test sum(p.vote_share for p in exact_party) == sum(p.seat_share for p in exact_party) == 1
    for quantity in exact_party
        @test quantity.d == quantity.q * (quantity.R - 1)
    end
    for members in (["A", "B"], ["B", "A"], ["A", "B", "A"])
        totals = Processing.coalition_totals(summary, members)
        @test totals == (votes = 49, seats = 257, national_vote_total = 100, total_seats = 513)
        metrics = Processing.coalition_accounting_metrics(totals.votes, totals.seats;
            national_vote_total = totals.national_vote_total, total_seats = totals.total_seats)
        @test metrics.coalition_inversion
        @test metrics.seat_diff ≈ sum(summary.seat_diff[[1, 3]])
        @test metrics.representation_ratio ≈ metrics.seat_share / metrics.vote_share
        @test metrics.representation_ratio ≈ 1 + metrics.seat_diff / metrics.quota
        @test metrics.seat_diff >= metrics.required_diff
    end
    @test Processing.coalition_totals(reverse(summary), ["B", "A"]) ==
        Processing.coalition_totals(summary, ["A", "B"])
    @test_throws ErrorException Processing.coalition_totals(summary, ["absent"])
    @test_throws ErrorException Processing.coalition_totals(vcat(summary, summary[1:1, :]), ["A"])
    for (votes, seats, expected) in ((49,257,true), (50,257,false), (51,257,false), (49,256,false))
        metrics = Processing.coalition_accounting_metrics(votes, seats; national_vote_total = 100)
        @test metrics.coalition_inversion == expected
        exact = Processing.exact_accounting(votes, seats; national_vote_total = 100)
        @test exact.inversion == expected
        @test (exact.d >= exact.r) == (seats >= 257)
        @test exact.q == Processing.proportional_quota(votes, 100, 513)
    end
    # Exact integer classification remains strict even above Float64 precision.
    votes = big(2)^60
    @test !Processing.coalition_accounting_metrics(votes, 257;
        national_vote_total = 2 * votes).coalition_inversion
    @test Processing.coalition_accounting_metrics(votes, 257;
        national_vote_total = 2 * votes + 1).coalition_inversion
    zero = Processing.coalition_accounting_metrics(0, 0; national_vote_total = 100)
    @test ismissing(zero.representation_ratio)
    @test zero.quota == zero.seat_diff == 0
    @test ismissing(Processing.exact_accounting(0, 0; national_vote_total = 100).R)
end

@testset "Canonical party identities fail closed" begin
    @test Processing.canonicalize_parties(["REPU", "PT"]; year = 2023, strict = true) == ["PT", "REPUBLICANOS"]
    @test_throws ErrorException Processing.canonicalize_parties(["PR"]; strict = true)
    @test_throws ErrorException Processing.canonicalize_parties(["PARTIDO_INEXISTENTE_ABC"]; year = 2023, strict = true)
end
