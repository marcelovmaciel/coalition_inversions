using Test, CSV, DataFrames, Dates, JSON3

include(joinpath(@__DIR__, "AccountingEvidence.jl"))
using .AccountingEvidence
const PSDIAG = AccountingEvidence
const SIZE_TEST_RAW = joinpath(@__DIR__, "..", "..", "..", "build", "results", "accounting", "raw")
size_test_exact(s) = map(x -> parse(BigInt, x), split(s, "//")) |> x -> x[1]//x[2]

# Reconstitute the already-generated exact objects for fast unit/regression
# checks. Production receives these objects directly from build_year_accounting.
function size_test_accounting(parties, cells)
    result = Dict{Int,Any}()
    for year in (2014, 2018, 2022)
        p = parties[parties.election_year .== year, :]
        c = cells[cells.election_year .== year, :]
        party = DataFrame(party = String.(p.party), votes = p.v_i, seats = p.s_i,
            A_exact = size_test_exact.(p.A_i_exact), B_exact = size_test_exact.(p.B_i_exact),
            d_exact = size_test_exact.(p.d_i_exact), quota_exact = size_test_exact.(p.q_i_exact))
        panel = DataFrame(party = String.(c.party), district = String.(c.electoral_unit),
            votes = c.v_id, seats = c.s_id, district_votes = c.V_d, district_seats = c.S_d,
            a_exact = size_test_exact.(c.a_id_exact), b_exact = size_test_exact.(c.b_id_exact))
        result[year] = (party = party, panel = panel, district = unique(select(panel, :district)),
            national_votes = first(p.V), national_seats = Int(first(p.S)),
            seat_majority_threshold = fld(Int(first(p.S)), 2) + 1, year = year)
    end
    return result
end

@testset "Permanent party-size and cabinet accounting diagnostics" begin
    parties = CSV.read(joinpath(SIZE_TEST_RAW, "party_accounting_all_years.csv"), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    cells = CSV.read(joinpath(SIZE_TEST_RAW, "party_district_accounting_all_years.csv"), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    periods = CSV.read(joinpath(SIZE_TEST_RAW, "coalition_period_quantities.csv"), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    accounting = size_test_accounting(parties, cells)
    original_parties, original_periods = deepcopy(parties), deepcopy(periods)
    source_before = deepcopy(accounting)
    diagnostic = build_party_size_diagnostics!(parties, periods, accounting)
    @test isequal(periods, original_periods)
    @test all(isequal(accounting[y].party, source_before[y].party) && isequal(accounting[y].panel, source_before[y].panel) for y in keys(accounting))
    @test isequal(parties, original_parties) # persisted panel matches a fresh build
    @test all(diagnostic.checks.passed)
    @test nrow(diagnostic.period_linkage) == nrow(periods)
    @test nrow(diagnostic.cabinet_sets) == length(unique(diagnostic.period_linkage.cabinet_party_set_id))
    @test length(unique(diagnostic.period_linkage.coalition_id)) == nrow(periods)
    for r in eachrow(diagnostic.period_linkage)
        set = only(eachrow(diagnostic.cabinet_sets[diagnostic.cabinet_sets.cabinet_party_set_id .== r.cabinet_party_set_id, :]))
        member_names = Set(strip.(split(set.coalition_parties, ",")))
        members = parties[(parties.election_year .== r.election_year) .& in.(parties.party, Ref(member_names)), :]
        @test sum(size_test_exact.(members.A_i_exact)) == size_test_exact(r.A_C_exact)
        @test sum(size_test_exact.(members.B_i_exact)) == size_test_exact(r.B_C_exact)
        @test set.A_C == r.A_C && set.B_C == r.B_C
    end
    for p in eachrow(parties)
        member_links = diagnostic.period_linkage[(diagnostic.period_linkage.election_year .== p.election_year) .&
            [p.party in split(only(diagnostic.cabinet_sets.canonical_membership[diagnostic.cabinet_sets.cabinet_party_set_id .== id]), ";") for id in diagnostic.period_linkage.cabinet_party_set_id], :]
        @test p.cabinet_observation_count == length(unique(member_links.cabinet_party_set_id))
        @test p.cabinet_distinct_set_count == p.cabinet_observation_count
        @test p.cabinet_analytical_period_count == nrow(member_links)
        @test p.cabinet_days == sum(member_links.days_overlapping_mandate)
        @test p.ever_in_cabinet == (nrow(member_links) > 0)
        @test p.A_over_q == Float64(size_test_exact(p.A_i_exact)/size_test_exact(p.q_i_exact))
    end
    # The release adapter is the chronology authority; compare the identified
    # registry membership and dates, preserving the full-calendar denominator.
    current = CSV.read(joinpath(@__DIR__, "..", "..", "..", "build", "results", "domains", "raw", "cabinet_coalition_metrics.csv"), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    @test nrow(current) == nrow(periods)
    @test Set(String.(periods.source_periods)) == Set(String.(current.source_periods))
    for year in (2014, 2018, 2022)
        party_year = parties[parties.election_year .== year, :]
        identity = Processing.cabinet_set_identity()
        identified = sum(identity.established_days[identity.election_year .== year])
        @test all(party_year.identified_cabinet_days .== identified)
        @test all(party_year.calendar_cabinet_days .== (year == 2022 ? 1174 : 1461))
        @test all(party_year.identified_cabinet_days .+ party_year.unidentified_cabinet_days .== party_year.calendar_cabinet_days)
    end

    @test PSDIAG.party_size_ranks([4, 1, 1, 3]) == [4, 1.5, 1.5, 3]
    @test ismissing(PSDIAG.party_size_correlation([1, 1], [1, 2]))
    @test ismissing(PSDIAG.party_size_correlation(Float64[], Float64[]))
    @test PSDIAG.PARTY_SIZE_BENCHMARK == 1//20
    # Boundary classification uses exact shares, not display rounding.
    bin(v) = PSDIAG.party_size_group(numerator(v), denominator(v))
    @test bin(1//100) == 2
    @test bin(3//100) == 3
    @test bin(5//100) == 4
    @test bin(4_999_999//100_000_000) == 3

    changed = deepcopy(diagnostic)
    changed.correlations.pearson_vote_share_A_over_q[1] -= 0.01
    @test_throws ErrorException validate_party_size_regressions(changed)
    if !isempty(periods)
        changed = deepcopy(diagnostic)
        changed.cabinet_sets.large_positive_minus_all_negative_A[1] += 1
        @test_throws ErrorException validate_party_size_regressions(changed)
        changed = deepcopy(diagnostic)
        changed.period_linkage.B_C[1] += 1
        @test_throws ErrorException validate_party_size_regressions(changed)
        repeated_id = first(diagnostic.period_linkage.cabinet_party_set_id)
        changed = deepcopy(diagnostic)
        row = findlast(==(repeated_id), changed.period_linkage.cabinet_party_set_id)
        deleteat!(changed.period_linkage, row)
        @test_throws ErrorException validate_party_size_regressions(changed)
    end
    broken_accounting = deepcopy(accounting)
    broken_accounting[2014].party.A_exact[1] += 1
    @test_throws ErrorException build_party_size_diagnostics!(copy(parties), periods, broken_accounting)
end

@testset "Effective party numbers use the existing exact shares" begin
    synthetic = DataFrame(election_year = [2014, 2014], v_i = [50, 50], V = [100, 100],
        s_i = [75, 25], S = [100, 100])
    summary = AccountingEvidence.party_fragmentation_summary(synthetic)
    @test only(summary.effective_electoral) == 2.0
    @test only(summary.effective_parliamentary) == 1.6
    @test only(summary.effective_parliamentary_exact) == "8//5"
end
