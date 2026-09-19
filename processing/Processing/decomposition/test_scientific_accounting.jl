using Test
using DataFrames
using Processing

isdefined(@__MODULE__, :CoalitionDecomposition) || include(joinpath(@__DIR__, "CoalitionDecomposition.jl"))
const CD_SCIENCE = CoalitionDecomposition

# Independent two-district example: three vote-receiving parties plus a party
# with zero votes/seats. A wins a strict minority; A+Z ties national votes.
function small_accounting_example()
    panel = DataFrame(district=repeat(["X", "Y"], inner=4),
        party=repeat(["A", "B", "Z", "N"], 2),
        votes=[10,20,10,0,20,30,10,0], seats=[2,1,0,0,1,1,0,0],
        district_votes=repeat([40,60], inner=4), district_seats=repeat([3,2], inner=4))
    panel.within_quota_exact = [BigInt(r.district_seats)*r.votes//r.district_votes for r in eachrow(panel)]
    panel.national_quota_contribution_exact = [BigInt(5)*r.votes//100 for r in eachrow(panel)]
    panel.a_exact = panel.seats .- panel.within_quota_exact
    panel.b_exact = panel.within_quota_exact .- panel.national_quota_contribution_exact
    panel.b_factored_exact = [BigInt(5)*(BigInt(r.district_seats)//5-BigInt(r.district_votes)//100)*
        (BigInt(r.votes)//r.district_votes) for r in eachrow(panel)]
    party = combine(groupby(panel, :party), :votes=>sum=>:votes, :seats=>sum=>:seats,
        :a_exact=>sum=>:A_exact, :b_exact=>sum=>:B_exact)
    party.quota_exact = [BigInt(5)*v//100 for v in party.votes]
    party.d_exact = party.seats .- party.quota_exact
    return (; year=0, panel, party, national_votes=100, national_seats=5, seat_majority_threshold=3)
end

@testset "Exact coalition accounting properties" begin
    a = small_accounting_example()
    @test sum(a.party.seats) == a.national_seats
    @test sum(a.party.quota_exact) == a.national_seats
    @test sum(a.party.d_exact) == 0
    @test a.party.d_exact == a.party.seats .- a.party.quota_exact
    names = ["A", "B", "Z", "N"]
    for mask in 0:15
        members = names[[!iszero(mask & (1 << (i-1))) for i in 1:4]]
        c = CD_SCIENCE.coalition_accounting(a, members; include_districts=true)
        reversed = CD_SCIENCE.coalition_accounting(a, reverse(members); include_districts=true)
        @test all(isequal(getproperty(c,k),getproperty(reversed,k)) for k in (:votes,:seats,:q,:d,:r,:A,:B,:R))
        @test c.d == c.seats-c.q == sum(c.members.d_exact; init=0)
        @test c.d == c.A+c.B
        @test c.A == sum(x.a_exact for x in c.districts)
        @test c.B == sum(x.b_exact for x in c.districts)
        @test c.status.coalition_inversion == (2*c.votes < a.national_votes && c.seats >= 3)
        @test iszero(c.q) ? ismissing(c.R) : c.R == c.seats/c.q == 1+c.d/c.q
    end
    oracle = CD_SCIENCE.coalition_accounting(a,["A"]; include_districts=true)
    @test (oracle.votes,oracle.seats,oracle.q,oracle.d,oracle.A,oracle.B,oracle.R)==(30,3,3//2,3//2,19//12,-1//12,2//1)
    @test oracle.status.coalition_inversion
    @test !CD_SCIENCE.coalition_accounting(a,["A","Z"]).status.coalition_inversion
    @test CD_SCIENCE.coalition_accounting(a,["Z"]).R == 0
    @test ismissing(CD_SCIENCE.coalition_accounting(a,["N"]).R)
    @test_throws ErrorException CD_SCIENCE.coalition_accounting(a,["A","A"])
    @test_throws ErrorException CD_SCIENCE.coalition_accounting(a,["absent"])
end
