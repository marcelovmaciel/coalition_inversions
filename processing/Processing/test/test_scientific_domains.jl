using Test
using DataFrames

@testset "Independent admissible-domain invariants" begin
    parties = ["A", "X", "B", "C", "Y", "D"]
    summary = DataFrame(SG_PARTIDO = parties, valid_total = [14, 26, 15, 14, 16, 15],
        total_seats = [130, 0, 126, 128, 0, 129])
    ideology = DataFrame(SG_PARTIDO = parties, ordinal_position = [2, 4, 6, 8, 10, 12])
    votes = Dict(zip(parties, summary.valid_total))
    seats = Dict(zip(parties, summary.total_seats))
    for universe in (:seat_winning, :all_parties)
        ordered = universe == :seat_winning ? ["A", "B", "C", "D"] : parties
        previous_keys = Set{Set{String}}()
        for k in (0, 1)
            # Enumerate every nonempty subset independently, then test its span.
            admissible = Set{String}[]
            for bits in 1:(2^length(ordered) - 1)
                positions = [i for i in eachindex(ordered) if bits & (1 << (i-1)) != 0]
                last(positions) - first(positions) + 1 - length(positions) <= k || continue
                push!(admissible, Set(ordered[positions]))
            end
            domain = Processing.ideological_k_gap_coalitions(summary, ideology; universe, k)
            keys = Set(Set(split(row.coalition_id, '|')) for row in eachrow(domain))
            @test keys == Set(admissible)
            @test issubset(previous_keys, keys)
            previous_keys = keys
            winning = [members for members in admissible if sum(seats[p] for p in members) >= 257]
            for row in eachrow(domain)
                members = Set(split(row.coalition_id, '|'))
                @test row.national_vote_total == 100
                @test row.votes == sum(votes[p] for p in members)
                @test row.seats == sum(seats[p] for p in members)
                @test row.inversion == (2 * row.votes < 100 && row.seats >= 257)
                minimal = members in winning && !any(other != members && issubset(other, members) for other in winning)
                @test row.minimal_seat_majority == minimal
                @test row.minimal_inversion == (minimal && row.inversion)
                @test row.d_C ≈ sum(seats[p] - 513 * votes[p] / 100 for p in members) atol=1e-10
            end
            permuted = Processing.ideological_k_gap_coalitions(reverse(summary), reverse(ideology); universe, k)
            @test isequal(domain, permuted)
            if k == 0
                interval = Processing.ideological_interval_view(domain)
                @test interval.coalition_id == domain.coalition_id
                @test interval.minimal_seat_majority == domain.minimal_seat_majority
                @test interval.quota == domain.q_C
            end
        end
    end
    primary = Processing.ideological_k_gap_coalitions(summary, ideology; universe = :seat_winning, k = 0)
    robustness = Processing.ideological_k_gap_coalitions(summary, ideology; universe = :all_parties, k = 1)
    @test "A|B" in primary.coalition_id
    @test "A|B" in robustness.coalition_id
    @test only(robustness.omitted_party[robustness.coalition_id .== "A|B"]) == "X"
    @test only(primary.vote_share[primary.coalition_id .== "A|B"]) == 0.29
    # Endpoint trimming is insufficient in D1: A+B+C loses on either trim,
    # yet A+C is a winning proper subset formed by omitting interior B.
    one_gap = Processing.ideological_k_gap_coalitions(summary, ideology; universe = :seat_winning, k = 1)
    abc = only(eachrow(one_gap[one_gap.coalition_id .== "A|B|C", :]))
    @test abc.seats - seats["A"] < 257 && abc.seats - seats["C"] < 257
    @test !abc.minimal_seat_majority
    @test only(primary.minimal_seat_majority[primary.coalition_id .== "A|B|C"])
    @test only(one_gap.seats[one_gap.coalition_id .== "A|C"]) >= 257

end

@testset "Domain input failures are explicit" begin
    summary=DataFrame(SG_PARTIDO=["A","B","Z"],valid_total=[40,50,10],total_seats=[257,256,0])
    ideology=DataFrame(SG_PARTIDO=["A","B","Z"],ordinal_position=[1,2,3])
    @test_throws ErrorException Processing.ideological_k_gap_coalitions(summary,ideology;k=2)
    @test_throws ErrorException Processing.ideological_k_gap_coalitions(summary,ideology;universe=:unsupported)
    @test_throws ErrorException Processing.ideological_party_order(summary,ideology[1:2,:])
    @test_throws ErrorException Processing.ideological_party_order(vcat(summary,summary[1:1,:]),ideology)
    @test_throws ErrorException Processing.ideological_party_order(summary,vcat(ideology,ideology[1:1,:]))
    tied=copy(ideology);tied.ordinal_position[2]=1
    @test_throws ErrorException Processing.ideological_party_order(summary,tied)
    for column in (:valid_total,:total_seats)
        negative=copy(summary);negative[1,column]=-1
        @test_throws ErrorException Processing.ideological_party_order(negative,ideology)
    end
end
