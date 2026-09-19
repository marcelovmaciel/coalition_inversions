module CoalitionDecomposition

using CSV
using DataFrames
using Dates
using Printf
using SHA

import ..Processing
import ..Processing.AnalysisRunnerCore as ARC

export ACCOUNTING_ATOL,
       ACCOUNTING_RTOL,
       build_year_accounting,
       coalition_accounting,
       write_coalition_accounting,
       recompute_coalition_periods,
       decompose_inversions,
       write_decomposition_outputs,
       validate_ideological_counts

const ACCOUNTING_ATOL = 1.0e-9
const ACCOUNTING_RTOL = 1.0e-12
const EXPECTED_TOTAL_SEATS = 513
const Rat = Rational{BigInt}

bigint(value::Integer) = BigInt(value)
exact_fraction(numerator::Integer, denominator::Integer) = bigint(numerator) // bigint(denominator)

function require(condition::Bool, message::AbstractString)
    condition || error(message)
    return true
end

function accounting_isapprox(left, right)
    return isapprox(Float64(left), Float64(right); atol = ACCOUNTING_ATOL, rtol = ACCOUNTING_RTOL)
end

function require_approx(left, right, label::AbstractString)
    accounting_isapprox(left, right) || error(
        "$(label): values differ (left=$(left), right=$(right), " *
        "atol=$(ACCOUNTING_ATOL), rtol=$(ACCOUNTING_RTOL)).",
    )
    return true
end

function split_parties(value)
    ismissing(value) && return String[] # CSV empty cell for an identified empty composition.
    parties = sort(String.(filter(!isempty, strip.(split(String(value), ",")))))
    length(parties) == length(unique(parties)) || error(
        "Coalition contains duplicate party labels: $(value)",
    )
    return parties
end

function canonical_party(raw_party, year::Integer)
    raw = strip(String(raw_party))
    canonical = Processing.canonical_party(raw; year = Int(year), strict = false)
    canonical == Processing.UNKNOWN_PARTY && error(
        "Unmapped federal-deputy party label for $(year): $(raw)",
    )
    return canonical
end

function canonicalize_party_column!(data::DataFrame, year::Integer)
    raw_values = String.(data.SG_PARTIDO)
    mapping = Dict(raw => canonical_party(raw, year) for raw in unique(raw_values))
    data[!, :SG_PARTIDO] = [mapping[raw] for raw in raw_values]
    return data
end

function load_district_votes(year::Integer, path::AbstractString)
    required_names = Set([
        "DS_CARGO",
        "SG_UF",
        "SG_PARTIDO",
        "QT_VOTOS_NOMINAIS_VALIDOS",
        "QT_VOTOS_NOMINAIS",
        "QT_TOTAL_VOTOS_LEG_VALIDOS",
        "QT_VOTOS_LEGENDA_VALIDOS",
        "QT_VOTOS_LEGENDA",
        "QT_VOTOS_NOMINAIS_CONVR_LEG",
        "QT_VOTOS_NOM_CONVR_LEG_VALIDOS",
        "QT_VOTOS",
        "TOTAL_VOTOS",
        "QT_VOTOS_VALIDOS",
    ])
    data = CSV.read(
        path,
        DataFrame;
        select = (_, name) -> String(name) in required_names,
    )
    Processing.upper_strip!(data, :DS_CARGO)
    filter!(row -> row.DS_CARGO == "DEPUTADO FEDERAL", data)
    nrow(data) > 0 || error("No federal-deputy vote rows for $(year): $(path)")

    # The office filter intentionally precedes strict party canonicalization.
    # This brackets the unrelated PCA14 non-federal row without weakening the
    # canonicalizer for any row used by the decomposition.
    Processing.stringify!(data, :SG_UF)
    Processing.stringify!(data, :SG_PARTIDO)
    canonicalize_party_column!(data, year)

    vote_kwargs = ARC.vote_kwargs_for_year(year)
    nominal_col, legend_col, total_col, scheme = Processing.detect_vote_cols(data; vote_kwargs...)
    valid_votes = if scheme == :total
        total_col === nothing && error("No total-vote column detected for $(year).")
        Processing.to_int.(data[!, total_col])
    else
        nominal_col === nothing && error("No nominal-vote column detected for $(year).")
        legend_col === nothing && error("No legend-vote column detected for $(year).")
        Processing.to_int.(data[!, nominal_col]) .+ Processing.to_int.(data[!, legend_col])
    end
    all(valid_votes .>= 0) || error("Negative federal-deputy votes detected for $(year).")

    district_votes = DataFrame(
        district = String.(data.SG_UF),
        party = String.(data.SG_PARTIDO),
        votes = Int.(valid_votes),
    )
    district_votes = combine(groupby(district_votes, [:district, :party]), :votes => sum => :votes)
    sort!(district_votes, [:district, :party])
    return district_votes
end

function load_district_seats(year::Integer, path::AbstractString)
    columns = [:DS_CARGO, :SG_UF, :SG_PARTIDO, :DS_SIT_TOT_TURNO]
    data = CSV.read(path, DataFrame; select = columns, normalizenames = true)
    Processing.upper_strip!(data, :DS_CARGO)
    filter!(row -> row.DS_CARGO == "DEPUTADO FEDERAL", data)
    nrow(data) > 0 || error("No federal-deputy candidate rows for $(year): $(path)")

    Processing.stringify!(data, :SG_UF)
    Processing.stringify!(data, :SG_PARTIDO)
    canonicalize_party_column!(data, year)
    winner_status = uppercase.(strip.(String.(data.DS_SIT_TOT_TURNO)))
    winners = in.(winner_status, Ref(Processing.WINNER_STATUSES))

    district_seats = DataFrame(
        district = String.(data.SG_UF),
        party = String.(data.SG_PARTIDO),
        seats = Int.(winners),
    )
    district_seats = combine(groupby(district_seats, [:district, :party]), :seats => sum => :seats)
    filter!(row -> row.seats > 0, district_seats)
    sort!(district_seats, [:district, :party])
    return district_seats
end

function load_apportioned_district_seats(year::Integer, path::AbstractString)
    columns = [:DS_CARGO, :SG_UF, :QT_VAGA]
    data = CSV.read(path, DataFrame; select = columns, normalizenames = true)
    Processing.upper_strip!(data, :DS_CARGO)
    filter!(row -> row.DS_CARGO == "DEPUTADO FEDERAL", data)
    nrow(data) > 0 || error("No federal-deputy apportionment rows for $(year): $(path)")

    Processing.stringify!(data, :SG_UF)
    apportioned = DataFrame(
        district = String.(data.SG_UF),
        apportioned_seats = Processing.to_int.(data.QT_VAGA),
    )
    apportioned = combine(
        groupby(apportioned, :district),
        :apportioned_seats => sum => :apportioned_seats,
    )
    sort!(apportioned, :district)
    nrow(apportioned) == 27 || error(
        "$(year): seat-apportionment file has $(nrow(apportioned)) federal-deputy units, not 27.",
    )
    sum(apportioned.apportioned_seats) == EXPECTED_TOTAL_SEATS || error(
        "$(year): seat-apportionment file does not sum to $(EXPECTED_TOTAL_SEATS).",
    )
    return apportioned
end

function complete_panel(votes::DataFrame, seats::DataFrame)
    vote_districts = Set(String.(votes.district))
    seat_districts = Set(String.(seats.district))
    vote_districts == seat_districts || error(
        "Vote and seat electoral-unit sets differ: votes=$(sort(collect(vote_districts))), " *
        "seats=$(sort(collect(seat_districts))).",
    )
    districts = sort(collect(vote_districts))
    parties = sort(collect(union(Set(String.(votes.party)), Set(String.(seats.party)))))
    length(districts) == 27 || error(
        "Expected Brazil's 27 federal-deputy electoral units; found $(length(districts)): " *
        join(districts, ", "),
    )

    vote_lookup = Dict(
        (String(row.district), String(row.party)) => Int(row.votes) for row in eachrow(votes)
    )
    seat_lookup = Dict(
        (String(row.district), String(row.party)) => Int(row.seats) for row in eachrow(seats)
    )
    rows = NamedTuple[]
    for district in districts, party in parties
        push!(rows, (
            district = district,
            party = party,
            votes = get(vote_lookup, (district, party), 0),
            seats = get(seat_lookup, (district, party), 0),
        ))
    end
    panel = DataFrame(rows)
    nrow(panel) == length(districts) * length(parties) || error(
        "Incomplete party-by-district panel.",
    )
    return panel
end

"""
    build_year_accounting(year, vote_path, candidate_path, apportionment_path;
                          expected_national_votes)

Load the same federal-deputy vote components and winner statuses used by the
validated paper runner, aggregate them by state, complete the party-by-state
panel with explicit zeroes, and compute the exact-rational accounting terms.
"""
function build_year_accounting(
    year::Integer,
    vote_path::AbstractString,
    candidate_path::AbstractString;
    apportionment_path::Union{Nothing,AbstractString} = nothing,
    expected_national_votes::Integer,
    expected_total_seats::Integer = EXPECTED_TOTAL_SEATS,
)
    district_votes = load_district_votes(year, vote_path)
    district_seats = load_district_seats(year, candidate_path)
    panel = complete_panel(district_votes, district_seats)

    national_votes = sum(panel.votes)
    national_seats = sum(panel.seats)
    national_votes == expected_national_votes || error(
        "$(year) national vote denominator changed: $(national_votes) != $(expected_national_votes).",
    )
    national_seats == expected_total_seats || error(
        "$(year) Chamber seats changed: $(national_seats) != $(expected_total_seats).",
    )

    district_totals = combine(
        groupby(panel, :district),
        :votes => sum => :district_votes,
        :seats => sum => :district_seats,
    )
    all(district_totals.district_votes .> 0) || error("$(year) contains a zero-vote electoral unit.")
    all(district_totals.district_seats .> 0) || error("$(year) contains a zero-seat electoral unit.")
    apportionment_path === nothing && error(
        "$(year): independent seats.csv input is required for district-magnitude validation.",
    )
    apportioned = load_apportioned_district_seats(year, apportionment_path)
    candidate_lookup = Dict(
        String(row.district) => Int(row.district_seats) for row in eachrow(district_totals)
    )
    apportioned_lookup = Dict(
        String(row.district) => Int(row.apportioned_seats) for row in eachrow(apportioned)
    )
    keys(candidate_lookup) == keys(apportioned_lookup) || error(
        "$(year): candidate and seats.csv electoral-unit sets differ.",
    )
    for district in sort(collect(keys(candidate_lookup)))
        candidate_lookup[district] == apportioned_lookup[district] || error(
            "$(year)/$(district): elected-candidate count $(candidate_lookup[district]) " *
            "differs from seats.csv magnitude $(apportioned_lookup[district]).",
        )
    end
    district_vote_lookup = Dict(String(row.district) => Int(row.district_votes) for row in eachrow(district_totals))
    district_seat_lookup = Dict(String(row.district) => Int(row.district_seats) for row in eachrow(district_totals))

    panel[!, :district_votes] = [district_vote_lookup[String(value)] for value in panel.district]
    panel[!, :district_seats] = [district_seat_lookup[String(value)] for value in panel.district]
    within_quota_exact = Rat[]
    national_quota_contribution_exact = Rat[]
    a_exact = Rat[]
    b_exact = Rat[]
    b_factored_exact = Rat[]
    for row in eachrow(panel)
        within_quota = Processing.proportional_quota(row.votes, row.district_votes, row.district_seats)
        national_contribution = Processing.proportional_quota(row.votes, national_votes, national_seats)
        a_value = exact_fraction(row.seats, 1) - within_quota
        b_value = within_quota - national_contribution
        b_factored = exact_fraction(national_seats, 1) *
            (exact_fraction(row.district_seats, national_seats) -
             exact_fraction(row.district_votes, national_votes)) *
            exact_fraction(row.votes, row.district_votes)
        b_value == b_factored || error(
            "$(year)/$(row.district)/$(row.party): defining and factored B terms differ.",
        )
        push!(within_quota_exact, within_quota)
        push!(national_quota_contribution_exact, national_contribution)
        push!(a_exact, a_value)
        push!(b_exact, b_value)
        push!(b_factored_exact, b_factored)
    end
    panel[!, :within_quota_exact] = within_quota_exact
    panel[!, :national_quota_contribution_exact] = national_quota_contribution_exact
    panel[!, :a_exact] = a_exact
    panel[!, :b_exact] = b_exact
    panel[!, :b_factored_exact] = b_factored_exact

    party = combine(
        groupby(panel, :party),
        :votes => sum => :votes,
        :seats => sum => :seats,
        :a_exact => sum => :A_exact,
        :b_exact => sum => :B_exact,
    )
    quota_exact = Rat[]
    differential_exact = Rat[]
    ratio_exact = Union{Missing,Rat}[]
    for row in eachrow(party)
        quantities = Processing.exact_accounting(Int(row.votes), Int(row.seats);
            national_vote_total=national_votes, total_seats=national_seats)
        quota, differential = quantities.q, quantities.d
        row.A_exact + row.B_exact == differential || error(
            "$(year)/$(row.party): A_i + B_i != d_i.",
        )
        ratio = quantities.R
        if ratio !== missing
            quota * (ratio - exact_fraction(1, 1)) == differential || error(
                "$(year)/$(row.party): q_i(R_i - 1) != d_i.",
            )
        elseif row.seats > 0
            error("$(year)/$(row.party) has positive seats and zero valid votes.")
        end
        push!(quota_exact, quota)
        push!(differential_exact, differential)
        push!(ratio_exact, ratio)
    end
    party[!, :quota_exact] = quota_exact
    party[!, :d_exact] = differential_exact
    party[!, :R_exact] = ratio_exact
    party[!, :vote_share] = Float64.(party.votes ./ national_votes)
    party[!, :seat_share] = Float64.(party.seats ./ national_seats)
    party[!, :quota] = Float64.(party.quota_exact)
    party[!, :d_i] = Float64.(party.d_exact)
    party[!, :A_i] = Float64.(party.A_exact)
    party[!, :B_i] = Float64.(party.B_exact)
    party[!, :R_i] = [value === missing ? missing : Float64(value) for value in party.R_exact]
    sort!(party, :party)

    sum(party.A_exact) == 0 || error("$(year): complete-system sum(A_i) != 0.")
    sum(party.B_exact) == 0 || error("$(year): complete-system sum(B_i) != 0.")
    sum(party.d_exact) == 0 || error("$(year): complete-system sum(d_i) != 0.")
    for group in groupby(panel, :district)
        sum(group.a_exact) == 0 || error(
            "$(year)/$(first(group.district)): district sum(a_id) != 0.",
        )
        expected_b_sum = exact_fraction(first(group.district_seats), 1) -
            Processing.proportional_quota(first(group.district_votes), national_votes, national_seats)
        sum(group.b_exact) == expected_b_sum || error(
            "$(year)/$(first(group.district)): district sum(b_id) closure failed.",
        )
    end

    return (
        year = Int(year),
        panel = panel,
        party = party,
        district = district_totals,
        national_votes = Int(national_votes),
        national_seats = Int(national_seats),
        seat_majority_threshold = fld(Int(national_seats), 2) + 1,
    )
end

function validate_party_baseline!(accounting, baseline::DataFrame)
    rows = baseline[Int.(baseline.election_year) .== accounting.year, :]
    nrow(rows) == nrow(accounting.party) || error(
        "$(accounting.year): district reconstruction has $(nrow(accounting.party)) parties, " *
        "baseline has $(nrow(rows)).",
    )
    baseline_parties = Set(String.(rows.party))
    panel_parties = Set(String.(accounting.party.party))
    baseline_parties == panel_parties || error(
        "$(accounting.year): district and national party sets differ.",
    )
    lookup = Dict(String(row.party) => row for row in eachrow(rows))
    for row in eachrow(accounting.party)
        source = lookup[String(row.party)]
        row.votes == source.votes || error("$(accounting.year)/$(row.party): vote total differs from baseline.")
        row.seats == source.seats || error("$(accounting.year)/$(row.party): seat total differs from baseline.")
        require_approx(row.quota, source.quota, "$(accounting.year)/$(row.party) q_i baseline")
        require_approx(row.d_i, source.seat_diff, "$(accounting.year)/$(row.party) d_i baseline")
        if row.R_i !== missing
            require_approx(row.R_i, source.representation_ratio, "$(accounting.year)/$(row.party) R_i baseline")
        end
    end
    return true
end

function majority_status(vote_majority::Bool, seat_majority::Bool)
    vote_majority && seat_majority && return "votes+seats"
    vote_majority && return "votes_only"
    seat_majority && return "seats_only"
    return "neither"
end

"""
    recompute_coalition_periods(observed, accounting_by_year; party_baseline)

Recompute every observed cabinet-period quantity from district-reconstructed
party totals, then compare it with the pinned contemporaneous-affiliation adapter output.
"""
function recompute_coalition_periods(
    observed::DataFrame,
    accounting_by_year::AbstractDict;
    party_baseline::Union{Nothing,DataFrame} = nothing,
)
    party_baseline === nothing || foreach(
        accounting -> validate_party_baseline!(accounting, party_baseline),
        values(accounting_by_year),
    )
    rows = NamedTuple[]
    for source in eachrow(observed)
        year = Int(source.election_year)
        accounting = accounting_by_year[year]
        parties = split_parties(source.parties)
        values = coalition_accounting(accounting, parties)
        coalition_votes, coalition_seats = values.votes, values.seats
        quota_exact, differential_exact, required_exact = values.q, values.d, values.r
        vote_share, seat_share = values.status.vote_share, values.status.seat_share
        ratio = iszero(quota_exact) ? missing : coalition_seats / Float64(quota_exact)
        vote_majority, seat_majority = values.status.vote_majority, values.status.seat_majority
        inversion = values.status.coalition_inversion
        canonical_parties = join(parties, ", ")

        canonical_parties == join(split_parties(source.parties), ", ") || error(
            "$(year)/$(source.period): coalition composition normalization changed.",
        )
        coalition_votes == Int(source.votes) || error("$(year)/$(source.period): v_C differs from pinned cabinet baseline.")
        coalition_seats == Int(source.seats) || error("$(year)/$(source.period): s_C differs from pinned cabinet baseline.")
        accounting.national_votes == Int(source.national_vote_total) || error(
            "$(year)/$(source.period): national vote denominator differs from pinned cabinet baseline.",
        )
        require_approx(vote_share, source.vote_share, "$(year)/$(source.period) vote share baseline")
        require_approx(quota_exact, source.quota, "$(year)/$(source.period) q_C baseline")
        require_approx(differential_exact, source.seat_diff, "$(year)/$(source.period) d_C baseline")
        require_approx(required_exact, source.required_diff, "$(year)/$(source.period) r_C baseline")
        if ismissing(ratio)
            ismissing(source.representation_ratio) || error("Zero-quota coalition must have undefined representation ratio")
        else
            require_approx(ratio, source.representation_ratio, "$(year)/$(source.period) R_C baseline")
        end
        inversion == Bool(source.coalition_inversion) || error(
            "$(year)/$(source.period): inversion classification differs from pinned cabinet baseline.",
        )

        push!(rows, (
            coalition_id = "$(year)/$(source.period)",
            election_year = year,
            coalition_year = Int(source.coalition_year),
            cabinet_period = string(source.period),
            source_periods = String(source.source_periods),
            period_start = Date(string(source.period_start)),
            period_end = Date(string(source.period_end)),
            period_days = Int(source.period_days),
            days_overlapping_mandate = Int(source.days_overlapping_mandate),
            coalition_parties = canonical_parties,
            coalition_party_count = length(parties),
            v_C = Int(coalition_votes),
            V = Int(accounting.national_votes),
            vote_share = Float64(vote_share),
            s_C = Int(coalition_seats),
            S = Int(accounting.national_seats),
            seat_share = Float64(seat_share),
            q_C = Float64(quota_exact),
            d_C = Float64(differential_exact),
            r_C = Float64(required_exact),
            R_C = ismissing(ratio) ? missing : Float64(ratio),
            vote_majority = Bool(vote_majority),
            seat_majority = Bool(seat_majority),
            majority_status = majority_status(vote_majority, seat_majority),
            coalition_inversion = Bool(inversion),
        ))
    end
    result = isempty(rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "coalition_year", "cabinet_period", "source_periods", "period_start", "period_end", "period_days", "days_overlapping_mandate", "share_of_mandate", "coalition_parties", "coalition_party_count", "v_C", "V", "vote_share", "s_C", "S", "seat_share", "q_C", "d_C", "r_C", "R_C", "vote_majority", "seat_majority", "majority_status", "coalition_inversion"]]) : DataFrame(rows)
    sort!(result, [:election_year, :period_start, :cabinet_period])

    length(unique(result.coalition_id)) == nrow(observed) || error("Cabinet registry lost or duplicated a period")
    return result
end

function exact_coalition_district(accounting, parties::Vector{String}, district::String)
    district_rows = accounting.panel[accounting.panel.district .== district, :]
    member_mask = in.(String.(district_rows.party), Ref(Set(parties)))
    members = district_rows[member_mask, :]
    v_Cd = sum(members.votes)
    s_Cd = sum(members.seats)
    V_d = first(district_rows.district_votes)
    S_d = first(district_rows.district_seats)
    within_quota = Processing.proportional_quota(v_Cd, V_d, S_d)
    national_contribution = Processing.proportional_quota(v_Cd, accounting.national_votes, accounting.national_seats)
    a_value = exact_fraction(s_Cd, 1) - within_quota
    b_value = within_quota - national_contribution
    b_factored = exact_fraction(accounting.national_seats, 1) *
        (exact_fraction(S_d, accounting.national_seats) -
         exact_fraction(V_d, accounting.national_votes)) *
        exact_fraction(v_Cd, V_d)
    b_value == b_factored || error("$(accounting.year)/$(district): coalition B_Cd cross-check failed.")
    sum(members.a_exact) == a_value || error("$(accounting.year)/$(district): party sum a_id != a_Cd.")
    sum(members.b_exact) == b_value || error("$(accounting.year)/$(district): party sum b_id != b_Cd.")
    return (
        v_Cd = Int(v_Cd),
        s_Cd = Int(s_Cd),
        V_d = Int(V_d),
        S_d = Int(S_d),
        within_quota_exact = within_quota,
        national_contribution_exact = national_contribution,
        a_exact = a_value,
        b_exact = b_value,
        b_factored_exact = b_factored,
    )
end

"""
    coalition_accounting(accounting, parties; include_districts=false)

The canonical coalition calculation. Membership is a set, the national vote
normalizer includes every party, and all accounting quantities remain rational.
Output adapters may preserve their own member ordering without changing totals.
"""
function coalition_accounting(accounting, parties::AbstractVector{<:AbstractString}; include_districts=false)
    length(parties) == length(unique(parties)) || error("Duplicate coalition parties.")
    requested = Set(String.(parties))
    available = Set(String.(accounting.party.party))
    isempty(setdiff(requested, available)) || error("Coalition contains parties absent from election accounting.")
    members = accounting.party[in.(String.(accounting.party.party), Ref(requested)), :]
    votes = sum(members.votes; init=0)
    seats = sum(members.seats; init=0)
    quantities = Processing.exact_accounting(votes, seats;
        national_vote_total=accounting.national_votes, total_seats=accounting.national_seats,
        seat_majority_threshold=accounting.seat_majority_threshold)
    q, d, r, R = quantities.q, quantities.d, quantities.r, quantities.R
    A = sum(members.A_exact; init=Rat(0))
    B = sum(members.B_exact; init=Rat(0))
    A + B == d || error("Coalition A + B differs from d.")
    sum(members.d_exact; init=Rat(0)) == d || error("Coalition party differentials do not close.")
    ismissing(R) || q * (R - 1) == d || error("Coalition representation identity failed.")
    status = (vote_share=Float64(quantities.vote_share), seat_share=Float64(quantities.seat_share),
        vote_majority=quantities.vote_majority, seat_majority=quantities.seat_majority,
        coalition_inversion=quantities.inversion)
    districts = include_districts ? [merge((district=String(district),),
        exact_coalition_district(accounting, String.(parties), String(district)))
        for district in sort(unique(String.(accounting.panel.district)))] : NamedTuple[]
    if include_districts
        sum(row.a_exact for row in districts) == A || error("Coalition district A vector does not close.")
        sum(row.b_exact for row in districts) == B || error("Coalition district B vector does not close.")
    end
    return (; votes, seats, q, d, r, A, B, R, members, districts, status)
end

"""Export one national accounting row per election/member set used by the analysis.

Domain identity (universe, k and minimality) belongs to the separate full domain
registry. The cabinet snapshot supplies memberships, never electoral quantities.
"""
function write_coalition_accounting(path, domain_path, cabinet_root, accounting_by_year)
    memberships = Set{Tuple{Int,String}}()
    canonical(value, separator) = ismissing(value) ? "" : join(sort(filter(!isempty,
        strip.(String.(split(String(value), separator))))), ";")
    for row in CSV.File(domain_path)
        push!(memberships, (Int(row.election), canonical(row.parties, ',')))
    end
    for filename in ("cabinet_periods.csv", "cabinet_sensitivity_periods.csv")
        for row in CSV.File(joinpath(cabinet_root, filename))
            push!(memberships, (Int(row.election_year), canonical(row.party_set, ';')))
        end
    end
    rows = NamedTuple[]
    for (year, membership) in sort(collect(memberships))
        a = accounting_by_year[year]
        parties = isempty(membership) ? String[] : String.(split(membership, ';'))
        c = coalition_accounting(a, parties)
        push!(rows, (election_year=year, coalition_members=membership,
            votes=c.votes, seats=c.seats, V=a.national_votes, S=a.national_seats,
            seat_majority_threshold=a.seat_majority_threshold,
            vote_share=c.status.vote_share, seat_share=c.status.seat_share,
            vote_share_exact=string(exact_fraction(c.votes,a.national_votes)),
            seat_share_exact=string(exact_fraction(c.seats,a.national_seats)),
            q_C=Float64(c.q), d_C=Float64(c.d), r_C=Float64(c.r),
            A_C=Float64(c.A), B_C=Float64(c.B), R_C=ismissing(c.R) ? missing : Float64(c.R),
            q_C_exact=string(c.q), d_C_exact=string(c.d), r_C_exact=string(c.r),
            A_C_exact=string(c.A), B_C_exact=string(c.B), R_C_exact=ismissing(c.R) ? missing : string(c.R),
            A_over_q=iszero(c.q) ? missing : Float64(c.A/c.q),
            B_over_q=iszero(c.q) ? missing : Float64(c.B/c.q),
            A_pct_quota=iszero(c.q) ? missing : Float64(100*c.A/c.q),
            B_pct_quota=iszero(c.q) ? missing : Float64(100*c.B/c.q),
            A_over_q_exact=iszero(c.q) ? missing : string(c.A/c.q),
            B_over_q_exact=iszero(c.q) ? missing : string(c.B/c.q),
            A_pct_quota_exact=iszero(c.q) ? missing : string(100*c.A/c.q),
            B_pct_quota_exact=iszero(c.q) ? missing : string(100*c.B/c.q),
            vote_majority=c.status.vote_majority, seat_majority=c.status.seat_majority,
            inversion=c.status.coalition_inversion))
    end
    data = DataFrame(rows)
    mkpath(dirname(path))
    # gzip -n omits temporary filename/time metadata; the canonical scientific
    # object is compressed once, without a persistent uncompressed duplicate.
    mktemp(dirname(path)) do temporary, io
        close(io)
        CSV.write(temporary, data)
        open(path, "w") do compressed
            run(pipeline(`gzip -n -c -- $temporary`, stdout=compressed))
        end
    end
    return data
end

function qualification_for_year(year::Integer)
    year in (2014, 2018) && return "ex post party accounting contribution; joint electoral lists"
    return "accounting attribution; not an independent causal effect"
end

"""
    decompose_inversions(coalition_periods, accounting_by_year)

Calculate A_C and B_C for all observed inversions, plus
the full member-party d_i vector and state-level contributions. All internal
identities are checked with exact rational arithmetic; decimal residuals are
also checked under ACCOUNTING_ATOL/ACCOUNTING_RTOL for output regressions.
"""
function decompose_inversions(coalition_periods::DataFrame, accounting_by_year::AbstractDict; inversions_only=true)
    inversion_rows = inversions_only ? coalition_periods[coalition_periods.coalition_inversion .== true, :] : coalition_periods
    decomposition_rows = NamedTuple[]
    party_rows = NamedTuple[]
    district_rows = NamedTuple[]
    validation_rows = NamedTuple[]

    for coalition in eachrow(inversion_rows)
        year = Int(coalition.election_year)
        period = String(coalition.cabinet_period)
        key = (year, period)
        accounting = accounting_by_year[year]
        parties = split_parties(coalition.coalition_parties)
        !inversions_only || coalition.vote_share < 0.5 || error("$(year)/$(period): decomposed coalition is not below 50% of votes.")
        !inversions_only || coalition.s_C >= accounting.seat_majority_threshold || error(
            "$(year)/$(period): decomposed coalition lacks a Chamber seat majority.",
        )

        values_C = coalition_accounting(accounting, parties; include_districts=true)
        for values in values_C.districts
            district = values.district
            push!(district_rows, (
                coalition_id = String(coalition.coalition_id),
                election_year = year,
                cabinet_period = period,
                source_periods = String(coalition.source_periods),
                coalition_parties = String(coalition.coalition_parties),
                electoral_unit = district,
                v_Cd = values.v_Cd,
                V_d = values.V_d,
                s_Cd = values.s_Cd,
                S_d = values.S_d,
                within_district_quota = Float64(values.within_quota_exact),
                national_quota_contribution = Float64(values.national_contribution_exact),
                a_Cd = Float64(values.a_exact),
                b_Cd = Float64(values.b_exact),
                b_Cd_factored = Float64(values.b_factored_exact),
                a_Cd_exact=string(values.a_exact), b_Cd_exact=string(values.b_exact),
                b_crosscheck_residual = Float64(values.b_exact - values.b_factored_exact),
            ))
        end
        A_exact, B_exact = values_C.A, values_C.B
        q_exact, d_exact, r_exact = values_C.q, values_C.d, values_C.r
        members = values_C.members

        require_approx(q_exact, coalition.q_C, "$(year)/$(period) q_C coalition output")
        require_approx(d_exact, coalition.d_C, "$(year)/$(period) d_C coalition output")
        require_approx(r_exact, coalition.r_C, "$(year)/$(period) r_C coalition output")
        require_approx(A_exact + B_exact, coalition.d_C, "$(year)/$(period) decimal A+B=d")
        require_approx(sum(Float64.(members.d_exact)), coalition.d_C, "$(year)/$(period) decimal sum(d_i)=d_C")

        for member in eachrow(members)
            push!(party_rows, (
                coalition_id = String(coalition.coalition_id),
                election_year = year,
                cabinet_period = period,
                source_periods = String(coalition.source_periods),
                coalition_parties = String(coalition.coalition_parties),
                party = String(member.party),
                v_i = Int(member.votes),
                V = Int(accounting.national_votes),
                vote_share = Float64(member.vote_share),
                s_i = Int(member.seats),
                S = Int(accounting.national_seats),
                seat_share = Float64(member.seat_share),
                q_i = Float64(member.quota_exact),
                R_i = member.R_exact === missing ? missing : Float64(member.R_exact),
                d_i = Float64(member.d_exact),
                q_i_exact=string(member.quota_exact), d_i_exact=string(member.d_exact),
                A_i_exact=string(member.A_exact), B_i_exact=string(member.B_exact),
                A_i = Float64(member.A_exact),
                B_i = Float64(member.B_exact),
                q_times_R_minus_1 = member.R_exact === missing ? missing :
                    Float64(member.quota_exact * (member.R_exact - exact_fraction(1, 1))),
                accounting_qualification = qualification_for_year(year),
            ))
        end

        push!(decomposition_rows, (
            coalition_id = String(coalition.coalition_id),
            election_year = year,
            coalition_year = Int(coalition.coalition_year),
            cabinet_period = period,
            source_periods = String(coalition.source_periods),
            period_start = coalition.period_start,
            period_end = coalition.period_end,
            period_days = Int(coalition.period_days),
            coalition_parties = String(coalition.coalition_parties),
            coalition_party_count = Int(coalition.coalition_party_count),
            vote_share = Float64(coalition.vote_share),
            vote_share_pct = 100 * Float64(coalition.vote_share),
            s_C = Int(coalition.s_C),
            q_C = Float64(q_exact),
            d_C = Float64(d_exact),
            r_C = Float64(r_exact),
            R_C = ismissing(coalition.R_C) ? missing : Float64(coalition.R_C),
            A_C = Float64(A_exact),
            B_C = Float64(B_exact),
            A_plus_B_residual = Float64(A_exact + B_exact - d_exact),
            party_d_residual = Float64(sum(members.d_exact) - d_exact),
            accounting_tolerance_atol = ACCOUNTING_ATOL,
            accounting_tolerance_rtol = ACCOUNTING_RTOL,
            interpretation = "accounting identity; B_C combines district seat weights, valid-vote weights, and coalition vote geography",
        ))
        for (check_name, residual) in (
            ("A_C + B_C = d_C", Float64(A_exact + B_exact - d_exact)),
            ("sum_i d_i = d_C", Float64(sum(members.d_exact) - d_exact)),
            ("sum_i A_i = A_C", Float64(sum(members.A_exact) - A_exact)),
            ("sum_i B_i = B_C", Float64(sum(members.B_exact) - B_exact)),
        )
            push!(validation_rows, (
                coalition_id = String(coalition.coalition_id),
                election_year = year,
                cabinet_period = period,
                source_periods = String(coalition.source_periods),
                check_name = check_name,
                exact_pass = residual == 0.0,
                floating_residual = residual,
                atol = ACCOUNTING_ATOL,
                rtol = ACCOUNTING_RTOL,
                status = "PASS",
            ))
        end
    end

    decomposition = isempty(decomposition_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "coalition_year", "cabinet_period", "source_periods", "period_start", "period_end", "period_days", "coalition_parties", "coalition_party_count", "vote_share", "vote_share_pct", "s_C", "q_C", "d_C", "r_C", "R_C", "A_C", "B_C", "A_plus_B_residual", "party_d_residual", "accounting_tolerance_atol", "accounting_tolerance_rtol", "interpretation"]]) : DataFrame(decomposition_rows)
    party_contributions = isempty(party_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "cabinet_period", "source_periods", "coalition_parties", "party", "v_i", "V", "vote_share", "s_i", "S", "seat_share", "q_i", "R_i", "d_i", "A_i", "B_i", "q_times_R_minus_1", "accounting_qualification"]]) : DataFrame(party_rows)
    district_contributions = isempty(district_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "cabinet_period", "source_periods", "coalition_parties", "electoral_unit", "v_Cd", "V_d", "s_Cd", "S_d", "within_district_quota", "national_quota_contribution", "a_Cd", "b_Cd", "b_Cd_factored", "b_crosscheck_residual"]]) : DataFrame(district_rows)
    validations = isempty(validation_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "cabinet_period", "source_periods", "check_name", "exact_pass", "floating_residual", "atol", "rtol", "status"]]) : DataFrame(validation_rows)
    sort!(decomposition, [:election_year, :period_start, :cabinet_period])
    sort!(party_contributions, [:election_year, :cabinet_period, :d_i], rev = [false, false, true])
    sort!(district_contributions, [:election_year, :cabinet_period, :electoral_unit])

    extreme_rows = NamedTuple[]
    for group in groupby(party_contributions, [:coalition_id, :election_year, :cabinet_period])
        positive = group[argmax(group.d_i), :]
        negative = group[argmin(group.d_i), :]
        positive.d_i > 0 || error("$(positive.coalition_id): no positive party d_i contribution.")
        # An inversion can contain no negative member contribution.
        push!(extreme_rows, (
            coalition_id = String(positive.coalition_id),
            election_year = Int(positive.election_year),
            cabinet_period = String(positive.cabinet_period),
            largest_positive_party = String(positive.party),
            largest_positive_d_i = Float64(positive.d_i),
            largest_negative_party = negative.d_i < 0 ? String(negative.party) : missing,
            largest_negative_d_i = negative.d_i < 0 ? Float64(negative.d_i) : missing,
            accounting_qualification = qualification_for_year(Int(positive.election_year)),
        ))
    end
    party_extremes = isempty(extreme_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "cabinet_period", "largest_positive_party", "largest_positive_d_i", "largest_negative_party", "largest_negative_d_i", "accounting_qualification"]]) : DataFrame(extreme_rows)
    sort!(party_extremes, [:election_year, :cabinet_period])

    component_rows = NamedTuple[]
    for row in eachrow(decomposition)
        for (component, value) in (("A_C", row.A_C), ("B_C", row.B_C), ("d_C", row.d_C))
            push!(component_rows, (
                coalition_id = String(row.coalition_id),
                election_year = Int(row.election_year),
                cabinet_period = String(row.cabinet_period),
                component = component,
                seats = Float64(value),
            ))
        end
    end
    component_figure_data = isempty(component_rows) ? DataFrame([name => Any[] for name in ["coalition_id", "election_year", "cabinet_period", "component", "seats"]]) : DataFrame(component_rows)

    return (
        decomposition = decomposition,
        party_contributions = party_contributions,
        party_extremes = party_extremes,
        district_contributions = district_contributions,
        component_figure_data = component_figure_data,
        validations = validations,
    )
end

function latex_escape(value)
    replacements = Dict(
        '\\' => "\\textbackslash{}",
        '&' => "\\&",
        '%' => "\\%",
        '$' => "\\\$",
        '#' => "\\#",
        '_' => "\\_",
        '{' => "\\{",
        '}' => "\\}",
        '~' => "\\textasciitilde{}",
        '^' => "\\textasciicircum{}",
    )
    io = IOBuffer()
    for character in string(value)
        print(io, get(replacements, character, string(character)))
    end
    return String(take!(io))
end

fmt2(value) = ismissing(value) ? "---" : @sprintf("%.2f", Float64(value))

function closure_preserving_display(d_C, A_C)
    d_milli = round(Int, 1000 * Float64(d_C))
    A_milli = round(Int, 1000 * Float64(A_C))
    B_milli = d_milli - A_milli
    return (
        d_C = @sprintf("%.3f", d_milli / 1000),
        A_C = @sprintf("%.3f", A_milli / 1000),
        B_C = @sprintf("%.3f", B_milli / 1000),
    )
end



function sha256_file(path::AbstractString)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end

function write_csv(path::AbstractString, data::DataFrame)
    mkpath(dirname(path))
    CSV.write(path, data; quotestrings = true)
    return path
end

"""Unidentified days retain the full calendar denominator in generated notes."""
function cabinet_unidentified_days(output_root)
    accounting_root = basename(output_root) == "all_parties" ? dirname(output_root) : output_root
    path = joinpath(dirname(accounting_root), "paper", "raw", "cabinet_unidentified_intervals.csv")
    isfile(path) || return 0
    data = CSV.read(path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    return sum(Int.(data.days); init=0)
end
function cabinet_identification_note(days)
    days == 0 && return ""
    return "\\par\\smallskip{\\footnotesize Identified full compositions only. " *
           "$(days) of 4096 observation days have an unidentified cabinet party set and unavailable inversion status.}"
end

function cabinet_date_convention_note(output_root)
    accounting_root = basename(output_root) == "all_parties" ? dirname(output_root) : output_root
    path = joinpath(dirname(accounting_root), "paper", "raw", "cabinet_calendar_status.csv")
    isfile(path) || return ""
    data = CSV.read(path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    bounded = any(column in propertynames(data) && any(v -> !(string(coalesce(v, "")) in ("", "[]", "false", "0")), data[!, column])
                  for column in (:bounded_affiliation_ids, :bounded_service_ids))
    provisional = :provisional_days in propertynames(data) ? sum(data.provisional_days) : 0
    provenance = provisional > 0 ? "\\par{\\footnotesize V5 primary sets include $(provisional) flagged provisional days; the underlying UNKNOWN affiliations remain unresolved.}" : ""
    return provenance * (bounded ? "\\par{\\footnotesize Recorded concrete date and affiliation sensitivities are reported separately.}" : "")
end

"""
    write_decomposition_outputs(output_root, coalition_periods, outputs)

Write machine-readable intermediaries first. The LaTeX assets are then created
only from CSVs read back from disk, preserving the pipeline boundary between
calculation and presentation.
"""
function write_decomposition_outputs(output_root::AbstractString, coalition_periods::DataFrame, outputs)
    raw_dir = joinpath(output_root, "raw")
    tables_dir = joinpath(output_root, "tables")
    figure_dir = joinpath(output_root, "figure_data")
    audit_dir = joinpath(output_root, "audit")
    foreach(mkpath, (raw_dir, tables_dir, figure_dir, audit_dir))

    artifacts = NamedTuple[]
    function record_csv(relative_path, data, artifact_type, description)
        path = joinpath(output_root, relative_path)
        write_csv(path, data)
        push!(artifacts, (
            path = relative_path,
            artifact_type = artifact_type,
            description = description,
            rows = nrow(data),
            columns = length(names(data)),
            sha256 = sha256_file(path),
        ))
        return path
    end

    record_csv(
        "raw/coalition_period_quantities.csv",
        coalition_periods,
        "raw",
        "Release-derived coalition quantities for every observed cabinet period.",
    )
    record_csv(
        "raw/inversion_decomposition.csv",
        outputs.decomposition,
        "raw",
        "Exact-audited A_C/B_C decomposition for all observed inversions.",
    )
    record_csv(
        "raw/inversion_party_contributions.csv",
        outputs.party_contributions,
        "raw",
        "Full party-level d_i, A_i, and B_i vectors for all observed inversions.",
    )
    record_csv(
        "raw/inversion_district_contributions.csv",
        outputs.district_contributions,
        "raw",
        "State-level a_Cd and b_Cd contributions for all observed inversions.",
    )
    decomposition_table_path = record_csv(
        "tables/table_observed_inversion_decomposition.csv",
        outputs.decomposition,
        "table",
        "Manuscript summary of coalition quantities and decomposition components.",
    )
    extremes_table_path = record_csv(
        "tables/table_inversion_party_contribution_extremes.csv",
        outputs.party_extremes,
        "table",
        "Largest positive and negative party accounting contributions by inversion.",
    )
    record_csv(
        "figure_data/inversion_decomposition_components.csv",
        outputs.component_figure_data,
        "figure_data",
        "Long-form A_C, B_C, and d_C values for decomposition visualization.",
    )
    record_csv(
        "audit/decomposition_identity_checks.csv",
        outputs.validations,
        "audit",
        "Exact and floating-point decomposition identity results.",
    )

    decomposition_from_csv = CSV.read(decomposition_table_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    extremes_from_csv = CSV.read(extremes_table_path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    manifest = DataFrame(artifacts)
    sort!(manifest, :path)
    manifest_path = joinpath(output_root, "artifact_manifest.csv")
    CSV.write(manifest_path, manifest)
    return manifest
end

function validate_ideological_counts(intervals::DataFrame)
    rows = NamedTuple[]
    for year in sort(unique(Int.(intervals.election_year)))
        selected = intervals[Int.(intervals.election_year) .== year, :]
        inversion = Bool.(selected.coalition_inversion)
        minimal = Bool.(selected.minimal_connected_inversion)
        all(.!minimal .| inversion) || error("Minimal inversion is not an inversion.")
        all(selected.vote_share[inversion] .< 0.5) || error("Inversion violates all-valid-vote threshold.")
        all(selected.seats[inversion] .>= 257) || error("Inversion violates Chamber seat threshold.")
        push!(rows, (
            election_year = year,
            ideological_universe = only(unique(String.(selected.ideological_universe))),
            coalition_inversions = sum(inversion),
            minimal_inversions = sum(minimal),
            status = "PASS",
        ))
    end
    return DataFrame(rows)
end

end
