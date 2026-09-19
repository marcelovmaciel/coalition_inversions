module AccountingIntegration

using CSV
using DataFrames
using Printf
using SHA

import ..CoalitionDecomposition

const CD = CoalitionDecomposition
const Rat = Rational{BigInt}

export focal_case_specs,
       build_district_electoral_weight,
       build_accounting_integration,
       write_accounting_integration_outputs

const SELECTED_PARTIES_BY_YEAR = Dict(
    2014 => ["PMDB", "PSD", "PT", "PSDB"],
    2018 => ["PP", "PR", "PSL", "PSC", "PSD"],
    2022 => ["UNIÃO", "PT", "MDB", "PSOL", "PSB", "PL", "PP", "REPUBLICANOS"],
)

require(condition::Bool, message::AbstractString) = condition ? true : error(message)

exact_fraction(numerator::Integer, denominator::Integer = 1) =
    BigInt(numerator) // BigInt(denominator)

exact_text(value::Rational) = string(numerator(value), "//", denominator(value))

function parse_exact(value)
    value isa Rational && return Rat(value)
    pieces = split(strip(String(value)), "//"; limit = 2)
    length(pieces) == 2 || error("Expected exact rational n//d, found $(value).")
    return parse(BigInt, pieces[1]) // parse(BigInt, pieces[2])
end

string_or_missing(value) = ismissing(value) ? missing : String(value)
int_or_missing(value) = ismissing(value) ? missing : Int(value)
bool_or_missing(value) = ismissing(value) ? missing : Bool(value)

function ordered_parties(value)
    parties = String.(filter(!isempty, strip.(split(String(value), ","))))
    length(parties) == length(unique(parties)) || error(
        "Coalition contains duplicate party labels: $(value)",
    )
    return parties
end

function component_sign_pattern(A, B)
    A > 0 && B > 0 && return "A+, B+"
    A > 0 && B < 0 && return "A+, B-"
    A < 0 && B > 0 && return "A-, B+"
    A < 0 && B < 0 && return "A-, B-"
    A == 0 && return B > 0 ? "A0, B+" : B < 0 ? "A0, B-" : "A0, B0"
    return A > 0 ? "A+, B0" : "A-, B0"
end

function threshold_interpretation(A, B, d, r)
    d < r && return "majority threshold not reached"
    A < r && B > 0 && return "positive B required to meet threshold"
    A >= r && B < 0 && return "A accounting-sufficient; B offsets"
    A >= r && B > 0 && return "A accounting-sufficient; B reinforces"
    A >= r && return "A accounting-sufficient; B neutral"
    return "threshold met through component combination"
end

function baseline_case_display(row)
    if String(row.case_domain) == "cabinet"
        return "Cabinet $(row.election_year)/$(row.case_label)"
    end
    return "Ideological $(row.election_year)/$(row.start_party)-$(row.end_party)"
end

function baseline_metadata(row, registry_order::Int)
    case_id = String(row.case_id)
    return (
        case_id = case_id,
        baseline_case_id = case_id,
        source_case_id = String(row.source_case_id),
        source_case_ids = case_id,
        analysis_variant = "baseline",
        case_domain = String(row.case_domain),
        ideological_universe = String(row.ideological_universe),
        k = row.k,
        gap_count = row.gap_count,
        case_order = Int(row.case_order),
        registry_order = registry_order,
        focal_order = String(row.case_domain) == "cabinet" ? Int(row.case_order) : missing,
        election_year = Int(row.election_year),
        case_label = String(row.case_label),
        case_display = baseline_case_display(row),
        cabinet_period = string_or_missing(row.cabinet_period),
        source_periods = string_or_missing(row.source_periods),
        period_start = row.period_start,
        period_end = row.period_end,
        period_days = row.period_days,
        ideology_start_index = int_or_missing(row.ideology_start_index),
        ideology_end_index = int_or_missing(row.ideology_end_index),
        start_party = string_or_missing(row.start_party),
        end_party = string_or_missing(row.end_party),
        minimal_inversion = bool_or_missing(row.minimal_inversion),
        minimal_status = String(row.minimal_status),
        observed_coalition = Bool(row.observed_coalition),
        synthetic_ideological_interval = Bool(row.synthetic_ideological_interval),
        main_text_focal = String(row.case_domain) == "cabinet",
        appendix_minimal = coalesce(row.minimal_inversion, false),
        shared_numerical_vector = Bool(row.compositionally_repeated),
        numerical_vector_group = String(row.composition_equivalence_group),
        source_registry = String(row.source_registry),
    )
end

function component_metadata(meta, coalition_parties::AbstractString)
    return (
        case_id = meta.case_id,
        baseline_case_id = meta.baseline_case_id,
        source_case_id = meta.source_case_id,
        source_case_ids = meta.source_case_ids,
        analysis_variant = meta.analysis_variant,
        case_domain = meta.case_domain,
        ideological_universe = meta.ideological_universe,
        k = meta.k,
        gap_count = meta.gap_count,
        case_order = meta.case_order,
        registry_order = meta.registry_order,
        focal_order = meta.focal_order,
        election_year = meta.election_year,
        case_label = meta.case_label,
        case_display = meta.case_display,
        cabinet_period = meta.cabinet_period,
        source_periods = meta.source_periods,
        period_start = meta.period_start,
        period_end = meta.period_end,
        period_days = meta.period_days,
        ideology_start_index = meta.ideology_start_index,
        ideology_end_index = meta.ideology_end_index,
        start_party = meta.start_party,
        end_party = meta.end_party,
        minimal_inversion = meta.minimal_inversion,
        minimal_status = meta.minimal_status,
        observed_coalition = meta.observed_coalition,
        synthetic_ideological_interval = meta.synthetic_ideological_interval,
        main_text_focal = meta.main_text_focal,
        appendix_minimal = meta.appendix_minimal,
        shared_numerical_vector = meta.shared_numerical_vector,
        numerical_vector_group = meta.numerical_vector_group,
        coalition_parties = String(coalition_parties),
    )
end

"""
    build_exact_case(accounting, parties, metadata)

Construct one party/state/cell accounting vector from the exact-rational
election accounting. This common path is used for baseline cases, focal-case
selection, and manuscript-facing diagnostics.
"""
function build_exact_case(accounting, parties::Vector{String}, metadata)
    values_C = CD.coalition_accounting(accounting, parties; include_districts=true)
    party_lookup = Dict(String(row.party) => row for row in eachrow(values_C.members))
    member_rows = [party_lookup[party] for party in parties]
    coalition_parties = join(parties, ", ")
    base = component_metadata(metadata, coalition_parties)
    v_C, s_C = values_C.votes, values_C.seats
    q_exact, d_exact, r_exact = values_C.q, values_C.d, values_C.r
    A_exact, B_exact = values_C.A, values_C.B
    R_exact = values_C.R
    A_minus_r_exact = A_exact - r_exact
    d_minus_r_exact = d_exact - r_exact
    seat_margin_exact = exact_fraction(s_C - accounting.seat_majority_threshold)
    d_minus_r_exact == seat_margin_exact || error(
        "$(metadata.case_id): d_C-r_C != s_C-majority threshold.",
    )

    party_rows = NamedTuple[]
    for (party_order, (party_name, row)) in enumerate(zip(parties, member_rows))
        push!(party_rows, merge(base, (
            coalition_party_order = party_order,
            party = party_name,
            v_i = Int(row.votes),
            V = Int(accounting.national_votes),
            vote_share = Float64(row.vote_share),
            s_i = Int(row.seats),
            S = Int(accounting.national_seats),
            seat_share = Float64(row.seat_share),
            q_i = Float64(row.quota_exact),
            R_i = ismissing(row.R_exact) ? missing : Float64(row.R_exact),
            A_i = Float64(row.A_exact),
            B_i = Float64(row.B_exact),
            d_i = Float64(row.d_exact),
            q_i_exact = exact_text(row.quota_exact),
            A_i_exact = exact_text(row.A_exact),
            B_i_exact = exact_text(row.B_exact),
            d_i_exact = exact_text(row.d_exact),
            accounting_qualification = "accounting attribution; not an independent causal effect",
        )))
    end

    state_rows = NamedTuple[]
    cell_rows = NamedTuple[]
    for values in values_C.districts
        district = values.district
        v_Cd, s_Cd, V_d, S_d = values.v_Cd, values.s_Cd, values.V_d, values.S_d
        within_exact, national_exact = values.within_quota_exact, values.national_contribution_exact
        a_exact, b_exact = values.a_exact, values.b_exact
        d_state_exact = a_exact + b_exact
        push!(state_rows, merge(base, (
            electoral_unit = district,
            v_Cd = v_Cd,
            V_d = V_d,
            district_coalition_vote_share = v_Cd / V_d,
            s_Cd = s_Cd,
            S_d = S_d,
            district_coalition_seat_share = s_Cd / S_d,
            within_district_quota = Float64(within_exact),
            national_quota_contribution = Float64(national_exact),
            a_Cd = Float64(a_exact),
            b_Cd = Float64(b_exact),
            d_Cd = Float64(d_state_exact),
            within_district_quota_exact = exact_text(within_exact),
            national_quota_contribution_exact = exact_text(national_exact),
            a_Cd_exact = exact_text(a_exact),
            b_Cd_exact = exact_text(b_exact),
            d_Cd_exact = exact_text(d_state_exact),
        )))
    end

    for (party_order, party_name) in enumerate(parties)
        member = party_lookup[party_name]
        member_cells = accounting.panel[String.(accounting.panel.party) .== party_name, :]
        nrow(member_cells) == 27 || error(
            "$(metadata.case_id)/$(party_name): expected 27 party-state cells.",
        )
        for cell in eachrow(member_cells)
            d_cell_exact = cell.a_exact + cell.b_exact
            push!(cell_rows, merge(base, (
                coalition_party_order = party_order,
                party = party_name,
                electoral_unit = String(cell.district),
                v_id = Int(cell.votes),
                V_d = Int(cell.district_votes),
                district_party_vote_share = cell.votes / cell.district_votes,
                s_id = Int(cell.seats),
                S_d = Int(cell.district_seats),
                district_party_seat_share = cell.seats / cell.district_seats,
                within_district_quota = Float64(cell.within_quota_exact),
                national_quota_contribution = Float64(cell.national_quota_contribution_exact),
                a_id = Float64(cell.a_exact),
                b_id = Float64(cell.b_exact),
                d_id = Float64(d_cell_exact),
                A_i = Float64(member.A_exact),
                B_i = Float64(member.B_exact),
                d_i = Float64(member.d_exact),
                a_id_exact = exact_text(cell.a_exact),
                b_id_exact = exact_text(cell.b_exact),
                d_id_exact = exact_text(d_cell_exact),
                accounting_qualification = "accounting attribution; not an independent causal effect",
            )))
        end
    end

    party = DataFrame(party_rows)
    state = DataFrame(state_rows)
    cells = DataFrame(cell_rows)
    total = merge(base, (
        coalition_party_count = length(parties),
        v_C = v_C,
        V = Int(accounting.national_votes),
        vote_share = v_C / accounting.national_votes,
        vote_share_pct = 100 * v_C / accounting.national_votes,
        s_C = s_C,
        S = Int(accounting.national_seats),
        seat_share = s_C / accounting.national_seats,
        q_C = Float64(q_exact),
        A_C = Float64(A_exact),
        B_C = Float64(B_exact),
        d_C = Float64(d_exact),
        r_C = Float64(r_exact),
        R_C = ismissing(R_exact) ? missing : Float64(R_exact),
        A_minus_r_C = Float64(A_minus_r_exact),
        d_minus_r_C = Float64(d_minus_r_exact),
        seat_margin = s_C - accounting.seat_majority_threshold,
        vote_majority = values_C.status.vote_majority,
        seat_majority = values_C.status.seat_majority,
        coalition_inversion = values_C.status.coalition_inversion,
        A_accounting_sufficient = A_exact >= r_exact,
        positive_B_required = d_exact >= r_exact && A_exact < r_exact && B_exact > 0,
        component_sign_pattern = component_sign_pattern(A_exact, B_exact),
        threshold_interpretation = threshold_interpretation(A_exact, B_exact, d_exact, r_exact),
        q_C_exact = exact_text(q_exact),
        A_C_exact = exact_text(A_exact),
        B_C_exact = exact_text(B_exact),
        d_C_exact = exact_text(d_exact),
        r_C_exact = exact_text(r_exact),
        R_C_exact = ismissing(R_exact) ? missing : exact_text(R_exact),
        A_minus_r_C_exact = exact_text(A_minus_r_exact),
        d_minus_r_C_exact = exact_text(d_minus_r_exact),
        seat_margin_exact = exact_text(seat_margin_exact),
        accounting_qualification = "accounting attribution; not an independent causal effect",
        interpretation = "accounting identity; B combines district seat weights, valid-vote and turnout differences, and coalition vote geography",
    ))

    sum(parse_exact.(party.A_i_exact)) == A_exact || error(
        "$(metadata.case_id): party A vector does not close.",
    )
    sum(parse_exact.(party.B_i_exact)) == B_exact || error(
        "$(metadata.case_id): party B vector does not close.",
    )
    sum(parse_exact.(party.d_i_exact)) == d_exact || error(
        "$(metadata.case_id): party d vector does not close.",
    )
    sum(parse_exact.(state.a_Cd_exact)) == A_exact || error(
        "$(metadata.case_id): state A vector does not close.",
    )
    sum(parse_exact.(state.b_Cd_exact)) == B_exact || error(
        "$(metadata.case_id): state B vector does not close.",
    )
    sum(parse_exact.(state.d_Cd_exact)) == d_exact || error(
        "$(metadata.case_id): state d vector does not close.",
    )
    sum(parse_exact.(cells.a_id_exact)) == A_exact || error(
        "$(metadata.case_id): party-state A cells do not close.",
    )
    sum(parse_exact.(cells.b_id_exact)) == B_exact || error(
        "$(metadata.case_id): party-state B cells do not close.",
    )
    sum(parse_exact.(cells.d_id_exact)) == d_exact || error(
        "$(metadata.case_id): party-state d cells do not close.",
    )

    return (total = total, party = party, state = state, cells = cells)
end

function stack_case_outputs(outputs)
    isempty(outputs) && error("Cannot stack an empty accounting case collection.")
    return (
        total = DataFrame([output.total for output in outputs]),
        party = reduce(
            (left, right) -> vcat(left, right; cols = :union),
            [output.party for output in outputs],
        ),
        state = reduce(
            (left, right) -> vcat(left, right; cols = :union),
            [output.state for output in outputs],
        ),
        cells = reduce(
            (left, right) -> vcat(left, right; cols = :union),
            [output.cells for output in outputs],
        ),
    )
end

function registry_row(registry::DataFrame, case_id::AbstractString)
    selected = registry[String.(registry.case_id) .== case_id, :]
    nrow(selected) == 1 || error(
        "Expected exactly one registry row for $(case_id), found $(nrow(selected)).",
    )
    return only(eachrow(selected))
end

function baseline_case_outputs(registry::DataFrame, accounting_by_year::AbstractDict)
    isempty(registry) && error("Accounting integration requires an audited inversion registry.")
    outputs = Any[]
    by_id = Dict{String,Any}()
    for (registry_order, row) in enumerate(eachrow(registry))
        case_id = String(row.case_id)
        haskey(by_id, case_id) && error("Duplicate case id in registry: $(case_id).")
        year = Int(row.election_year)
        haskey(accounting_by_year, year) || error("No accounting panel for $(year).")
        output = build_exact_case(
            accounting_by_year[year],
            ordered_parties(row.coalition_parties),
            baseline_metadata(row, registry_order),
        )
        push!(outputs, output)
        by_id[case_id] = output
    end

    return stack_case_outputs(outputs), by_id
end

function ranked_contributor(
    members::DataFrame,
    exact_values::Vector{Rat},
    ranked_indices::Vector{Int},
    rank::Int,
)
    rank <= length(ranked_indices) || return (
        party = missing,
        value = missing,
        value_exact = missing,
    )
    index = ranked_indices[rank]
    return (
        party = String(members.party[index]),
        value = Float64(exact_values[index]),
        value_exact = exact_text(exact_values[index]),
    )
end

function build_party_contribution_focal_summary(summary::DataFrame)
    # The appendix retains every cabinet inversion and every primary minimal
    # exact-connected inversion, selected from the current audited registry.
    focal = summary[(summary.domain .== "cabinet") .|
        coalesce.(summary.minimal_ideological_inversion, false), :]
    sort!(focal, [:domain, :election, :case_order])
    focal[!, :focal_order] = collect(1:nrow(focal))
    focal[!, :source_case_identifiers] = String.(focal.case_identifier)
    sum(focal.domain .== "cabinet") == sum(summary.domain .== "cabinet") || error("Cabinet focal vectors lost cases.")
    return focal
end

"""
    build_coalition_party_contribution_diagnostics(baseline, registry)

Expose the already-audited exact party vectors for every inversion in the final
registry. This function does not calculate party quotas or differentials; it
adds case metadata, exact-sign rankings, summaries, and validation checks to the
values returned by build_exact_case.
"""
function build_coalition_party_contribution_diagnostics(
    baseline,
    registry::DataFrame,
)

    Set(String.(baseline.total.case_id)) == Set(String.(registry.case_id)) || error(
        "Party-contribution cases differ from the final inversion registry.",
    )

    contribution_rows = NamedTuple[]
    summary_rows = NamedTuple[]
    check_rows = NamedTuple[]
    registry_lookup = Dict(String(row.case_id) => row for row in eachrow(registry))

    for total in eachrow(baseline.total)
        case_id = String(total.case_id)
        haskey(registry_lookup, case_id) || error(
            "Party-contribution case is absent from the source registry: $(case_id).",
        )
        source = registry_lookup[case_id]
        members = baseline.party[String.(baseline.party.case_id) .== case_id, :]
        nrow(members) == Int(total.coalition_party_count) || error(
            "$(case_id): party-vector cardinality differs from coalition membership.",
        )

        exact_values = parse_exact.(members.d_i_exact)
        positive_indices = [i for i in eachindex(exact_values) if exact_values[i] > 0]
        negative_indices = [i for i in eachindex(exact_values) if exact_values[i] < 0]
        zero_indices = [i for i in eachindex(exact_values) if exact_values[i] == 0]
        sort!(positive_indices; by = i -> (-exact_values[i], String(members.party[i])))
        sort!(negative_indices; by = i -> (exact_values[i], String(members.party[i])))

        positive_ranks = Vector{Union{Missing,Int}}(missing, nrow(members))
        negative_ranks = Vector{Union{Missing,Int}}(missing, nrow(members))
        for (rank, index) in enumerate(positive_indices)
            positive_ranks[index] = rank
        end
        for (rank, index) in enumerate(negative_indices)
            negative_ranks[index] = rank
        end

        gross_positive_exact = sum(exact_values[positive_indices]; init = Rat(0))
        gross_negative_exact = -sum(exact_values[negative_indices]; init = Rat(0))
        d_sum_exact = sum(exact_values; init = Rat(0))
        d_C_exact = parse_exact(total.d_C_exact)
        gross_positive_exact - gross_negative_exact == d_sum_exact || error(
            "$(case_id): gross positive minus gross negative does not equal sum(d_i).",
        )
        d_sum_exact == d_C_exact || error(
            "$(case_id): exact party differential vector does not close to d_C.",
        )

        largest_positive = ranked_contributor(
            members, exact_values, positive_indices, 1,
        )
        second_positive = ranked_contributor(
            members, exact_values, positive_indices, 2,
        )
        largest_negative = ranked_contributor(
            members, exact_values, negative_indices, 1,
        )
        second_negative = ranked_contributor(
            members, exact_values, negative_indices, 2,
        )

        for (index, row) in enumerate(eachrow(members))
            sign = exact_values[index] > 0 ? "positive" :
                exact_values[index] < 0 ? "negative" : "zero"
            push!(contribution_rows, (
                election = Int(total.election_year),
                domain = String(total.case_domain),
            ideological_universe = String(total.ideological_universe),
            k = total.k,
            gap_count = total.gap_count,

                case_identifier = case_id,
                case = String(total.case_display),
                case_order = Int(total.case_order),
                cabinet_period = total.cabinet_period,
                source_periods = total.source_periods,
                period_start = total.period_start,
                period_end = total.period_end,
                period_days = total.period_days,
                coalition_start_party = total.start_party,
                coalition_end_party = total.end_party,
                minimal_ideological_inversion = total.minimal_inversion,
                coalition_parties = String(total.coalition_parties),
                coalition_party_count = Int(total.coalition_party_count),
                party_order = Int(row.coalition_party_order),
                party = String(row.party),
                party_vote_total = Int(row.v_i),
                national_vote_total = Int(row.V),
                party_vote_share = Float64(row.vote_share),
                party_seats = Int(row.s_i),
                chamber_seats = Int(row.S),
                party_quota_q_i = Float64(row.q_i),
                party_differential_d_i = Float64(row.d_i),
                coalition_vote_total = Int(total.v_C),
                coalition_vote_share = Float64(total.vote_share),
                coalition_seats = Int(total.s_C),
                coalition_quota_q_C = Float64(total.q_C),
                coalition_differential_d_C = Float64(total.d_C),
                contribution_sign = sign,
                rank_among_positive_contributors = positive_ranks[index],
                rank_among_negative_contributors = negative_ranks[index],
                A_i = Float64(row.A_i),
                B_i = Float64(row.B_i),
                A_C = Float64(total.A_C),
                B_C = Float64(total.B_C),
                party_quota_q_i_exact = String(row.q_i_exact),
                party_differential_d_i_exact = String(row.d_i_exact),
                coalition_quota_q_C_exact = String(total.q_C_exact),
                coalition_differential_d_C_exact = String(total.d_C_exact),
                A_i_exact = String(row.A_i_exact),
                B_i_exact = String(row.B_i_exact),
                A_C_exact = String(total.A_C_exact),
                B_C_exact = String(total.B_C_exact),
                contribution_vector_group = String(total.numerical_vector_group),
                contribution_vector_repeated = Bool(total.shared_numerical_vector),
                accounting_qualification = String(row.accounting_qualification),
            ))
        end

        top_two_positive_exact = sum(
            exact_values[positive_indices[1:min(2, length(positive_indices))]];
            init = Rat(0),
        )
        top_two_negative_exact = -sum(
            exact_values[negative_indices[1:min(2, length(negative_indices))]];
            init = Rat(0),
        )
        gross_absolute_exact = gross_positive_exact + gross_negative_exact
        cancellation_share = gross_absolute_exact == 0 ? 0.0 :
            1 - Float64(abs(d_sum_exact) / gross_absolute_exact)

        push!(summary_rows, (
            election = Int(total.election_year),
            domain = String(total.case_domain),
            ideological_universe = String(total.ideological_universe),
            k = total.k,
            gap_count = total.gap_count,
            case_identifier = case_id,
            case = String(total.case_display),
            case_order = Int(total.case_order),
            cabinet_period = total.cabinet_period,
            source_periods = total.source_periods,
            period_start = total.period_start,
            period_end = total.period_end,
            period_days = total.period_days,
            coalition_start_party = total.start_party,
            coalition_end_party = total.end_party,
            minimal_ideological_inversion = total.minimal_inversion,
            coalition_parties = String(total.coalition_parties),
            coalition_party_count = Int(total.coalition_party_count),
            coalition_vote_total = Int(total.v_C),
            coalition_vote_share = Float64(total.vote_share),
            coalition_seats = Int(total.s_C),
            coalition_quota_q_C = Float64(total.q_C),
            d_C = Float64(d_C_exact),
            gross_positive_party_contribution = Float64(gross_positive_exact),
            gross_negative_party_contribution = Float64(gross_negative_exact),
            net_party_contribution = Float64(d_sum_exact),
            positive_party_count = length(positive_indices),
            negative_party_count = length(negative_indices),
            zero_party_count = length(zero_indices),
            largest_positive_contributor = largest_positive.party,
            largest_positive_d_i = largest_positive.value,
            second_largest_positive_contributor = second_positive.party,
            second_largest_positive_d_i = second_positive.value,
            largest_negative_contributor = largest_negative.party,
            largest_negative_d_i = largest_negative.value,
            second_largest_negative_contributor = second_negative.party,
            second_largest_negative_d_i = second_negative.value,
            largest_positive_share_of_gross_positive =
                gross_positive_exact == 0 ? missing :
                Float64(parse_exact(largest_positive.value_exact) / gross_positive_exact),
            top_two_positive_share_of_gross_positive =
                gross_positive_exact == 0 ? missing :
                Float64(top_two_positive_exact / gross_positive_exact),
            largest_negative_share_of_gross_negative =
                gross_negative_exact == 0 ? missing :
                Float64(-parse_exact(largest_negative.value_exact) / gross_negative_exact),
            top_two_negative_share_of_gross_negative =
                gross_negative_exact == 0 ? missing :
                Float64(top_two_negative_exact / gross_negative_exact),
            cancellation_share = cancellation_share,
            d_C_exact = exact_text(d_C_exact),
            gross_positive_party_contribution_exact = exact_text(gross_positive_exact),
            gross_negative_party_contribution_exact = exact_text(gross_negative_exact),
            net_party_contribution_exact = exact_text(d_sum_exact),
            largest_positive_d_i_exact = largest_positive.value_exact,
            second_largest_positive_d_i_exact = second_positive.value_exact,
            largest_negative_d_i_exact = largest_negative.value_exact,
            second_largest_negative_d_i_exact = second_negative.value_exact,
            contribution_vector_group = String(total.numerical_vector_group),
            contribution_vector_repeated = Bool(total.shared_numerical_vector),
            exact_closure_pass = d_sum_exact == d_C_exact,
        ))

        sum_party_votes = sum(Int.(members.v_i))
        sum_party_seats = sum(Int.(members.s_i))
        party_votes_match = sum_party_votes == Int(total.v_C) == Int(source.v_C)
        party_seats_match = sum_party_seats == Int(total.s_C) == Int(source.s_C)
        membership_match = String(total.coalition_parties) == String(source.coalition_parties)
        denominator_match = Int(total.V) == Int(source.V) &&
            Int(total.S) == Int(source.S)
        vote_share_match = CD.accounting_isapprox(total.vote_share, source.vote_share)
        seat_share_match = CD.accounting_isapprox(total.seat_share, source.seat_share)
        q_match = CD.accounting_isapprox(total.q_C, source.q_C)
        d_match = CD.accounting_isapprox(total.d_C, source.d_C)
        r_match = CD.accounting_isapprox(total.r_C, source.r_C)
        R_match = CD.accounting_isapprox(total.R_C, source.R_C)
        remains_inversion = Bool(total.coalition_inversion) &&
            2 * Int(source.v_C) < Int(source.V) &&
            2 * Int(source.s_C) > Int(source.S)
        all_pass = party_votes_match && party_seats_match &&
            d_sum_exact == d_C_exact && membership_match && denominator_match &&
            vote_share_match && seat_share_match && q_match && d_match &&
            r_match && R_match && remains_inversion

        all_pass || error("$(case_id): party-contribution validation failed.")
        push!(check_rows, (
            election = Int(total.election_year),
            domain = String(total.case_domain),
            ideological_universe = String(total.ideological_universe),
            k = total.k,
            gap_count = total.gap_count,
            case_identifier = case_id,
            case = String(total.case_display),
            sum_party_votes = sum_party_votes,
            coalition_votes = Int(total.v_C),
            sum_party_votes_matches_coalition = party_votes_match,
            sum_party_seats = sum_party_seats,
            coalition_seats = Int(total.s_C),
            sum_party_seats_matches_coalition = party_seats_match,
            sum_party_d_i = Float64(d_sum_exact),
            coalition_d_C = Float64(d_C_exact),
            sum_party_d_i_exact = exact_text(d_sum_exact),
            coalition_d_C_exact = exact_text(d_C_exact),
            exact_differential_closure = d_sum_exact == d_C_exact,
            coalition_membership_matches_source = membership_match,
            national_denominators_match_source = denominator_match,
            coalition_vote_share_matches_source = vote_share_match,
            coalition_seat_share_matches_source = seat_share_match,
            coalition_q_C_matches_source = q_match,
            coalition_d_C_matches_source = d_match,
            coalition_r_C_matches_source = r_match,
            coalition_R_C_matches_source = R_match,
            coalition_remains_inversion = remains_inversion,
            all_checks_pass = all_pass,
        ))
    end

    contributions = DataFrame(contribution_rows)
    summary = DataFrame(summary_rows)
    checks = DataFrame(check_rows)
    sort!(contributions, [:domain, :election, :case_order, :party_order])
    sort!(summary, [:domain, :election, :case_order])
    sort!(checks, [:domain, :election, :case_identifier])

    nrow(contributions) == nrow(baseline.party) || error("Canonical party vector lost members.")
    nrow(summary) == nrow(baseline.total) || error("Case summary lost registry rows.")
    sum(contributions.domain .== "cabinet") == sum(baseline.party.case_domain .== "cabinet") || error("Cabinet case-party rows lost members.")
    all(checks.all_checks_pass) || error("A party-contribution audit check failed.")

    focal_summary = build_party_contribution_focal_summary(summary)

    pp_pl_cases = summary[(summary.election .== 2022) .&
        coalesce.(summary.coalition_start_party .== "PP", false) .&
        coalesce.(summary.coalition_end_party .== "PL", false) .&
        coalesce.(summary.minimal_ideological_inversion, false), :]
    named_rows = NamedTuple[]
    for pp_pl_summary in eachrow(pp_pl_cases)
        pp_pl_rows = contributions[(contributions.case_identifier .== pp_pl_summary.case_identifier) .&
            in.(String.(contributions.party), Ref(Set(["PL", "PP"]))), :]
        nrow(pp_pl_rows) == 2 || error("PP-PL named aggregation lost PL or PP.")
        combined = sum(parse_exact.(pp_pl_rows.party_differential_d_i_exact); init = Rat(0))
        d = parse_exact(pp_pl_summary.d_C_exact)
        share = combined / d
        push!(named_rows, (
            case_identifier = String(pp_pl_summary.case_identifier),
            ideological_universe = String(pp_pl_summary.ideological_universe),
            case = String(pp_pl_summary.case), parties = "PL + PP",
            combined_d_i = Float64(combined), d_C = Float64(d),
            share_of_d_C = Float64(share), share_of_d_C_pct = 100 * Float64(share),
            combined_d_i_exact = exact_text(combined), d_C_exact = exact_text(d),
            share_of_d_C_exact = exact_text(share),
            accounting_qualification = "descriptive accounting share; not a causal effect",
        ))
    end
    named_aggregates = DataFrame(named_rows)

    return (
        contributions = contributions,
        summary = summary,
        focal_summary = focal_summary,
        checks = checks,
        named_aggregates = named_aggregates,
    )
end

function focal_metadata(row, registry_order::Int, spec)
    base = baseline_metadata(row, registry_order)
    return merge(base, (
        case_id = spec.case_id,
        baseline_case_id = first(spec.source_case_ids),
        source_case_id = join(spec.source_case_ids, "; "),
        source_case_ids = join(spec.source_case_ids, "; "),
        analysis_variant = "focal",
        case_order = spec.case_order,
        focal_order = spec.case_order,
        case_label = spec.case_display,
        case_display = spec.case_display,
        cabinet_period = base.cabinet_period,
        main_text_focal = true,
        numerical_vector_group = spec.case_id,
    ))
end

function focal_case_specs(registry::DataFrame, by_id)
    cabinets = registry[registry.case_domain .== "cabinet", :]
    specs = NamedTuple[(case_order = i, case_id = String(row.case_id),
        source_case_ids = [String(row.case_id)], case_display = baseline_case_display(row))
        for (i, row) in enumerate(eachrow(cabinets))]
    minimal = registry[coalesce.(registry.minimal_inversion, false), :]
    chosen = Set{String}()
    for year in sort(unique(Int.(minimal.election_year)))
        candidates = sort(minimal[minimal.election_year .== year, :], [:v_C, :coalition_party_count, :case_id])
        push!(chosen, String(first(candidates.case_id)))
    end
    for row in eachrow(minimal)
        by_id[String(row.case_id)].total.B_C > by_id[String(row.case_id)].total.A_C &&
            push!(chosen, String(row.case_id))
    end
    for row in eachrow(sort(minimal, [:election_year, :ideology_start_index, :ideology_end_index]))
        String(row.case_id) in chosen || continue
        push!(specs, (case_order = length(specs) + 1, case_id = String(row.case_id),
            source_case_ids = [String(row.case_id)], case_display = baseline_case_display(row)))
    end
    return specs
end

function build_focal_outputs(registry::DataFrame, accounting_by_year::AbstractDict, by_id)
    outputs = Any[]
    specs = focal_case_specs(registry, by_id)
    for spec in specs
        source_row = registry_row(registry, first(spec.source_case_ids))
        registry_order = findfirst(
            ==(first(spec.source_case_ids)),
            String.(registry.case_id),
        )
        output = build_exact_case(
            accounting_by_year[Int(source_row.election_year)],
            ordered_parties(source_row.coalition_parties),
            focal_metadata(source_row, registry_order, spec),
        )
        push!(outputs, output)
    end
    focal = stack_case_outputs(outputs)
    String.(focal.total.case_id) == [spec.case_id for spec in specs] || error(
        "Focal accounting registry order changed.",
    )
    nrow(focal.state) == nrow(focal.total) * 27 || error("Every focal case must contain all 27 state rows.")
    return focal
end

sum_exact(values) = foldl(+, values; init = exact_fraction(0))

function signed_extreme(values, units, positive::Bool)
    indices = findall(value -> positive ? value > 0 : value < 0, values)
    isempty(indices) && return (unit = missing, value = exact_fraction(0))
    ordered = sort(
        indices;
        by = index -> positive ?
            (-values[index], String(units[index])) :
            (values[index], String(units[index])),
    )
    index = first(ordered)
    return (unit = String(units[index]), value = values[index])
end

function gross_component_summary(focal)
    rows = NamedTuple[]
    configurations = (
        (
            level = "party",
            data = focal.party,
            unit = :party,
            components = (
                ("A", :A_i_exact, :A_C_exact),
                ("B", :B_i_exact, :B_C_exact),
                ("d", :d_i_exact, :d_C_exact),
            ),
        ),
        (
            level = "state",
            data = focal.state,
            unit = :electoral_unit,
            components = (
                ("A", :a_Cd_exact, :A_C_exact),
                ("B", :b_Cd_exact, :B_C_exact),
                ("d", :d_Cd_exact, :d_C_exact),
            ),
        ),
    )

    for total in eachrow(focal.total)
        case_id = String(total.case_id)
        for configuration in configurations
            selected = configuration.data[
                String.(configuration.data.case_id) .== case_id,
                :,
            ]
            units = String.(selected[!, configuration.unit])
            for (component, exact_column, total_column) in configuration.components
                values = parse_exact.(selected[!, exact_column])
                positive_values = [value for value in values if value > 0]
                negative_values = [value for value in values if value < 0]
                gross_positive = sum_exact(positive_values)
                gross_negative = -sum_exact(negative_values)
                gross_absolute = gross_positive + gross_negative
                net = sum_exact(values)
                expected_net = parse_exact(getproperty(total, total_column))
                net == expected_net || error(
                    "$(case_id)/$(configuration.level)/$(component) gross vector does not close.",
                )
                positive = signed_extreme(values, units, true)
                negative = signed_extreme(values, units, false)
                absolute_shares = gross_absolute == 0 ? Float64[] :
                    [Float64(abs(value) / gross_absolute) for value in values]
                push!(rows, (
                    case_id = case_id,
                    case_display = String(total.case_display),
                    focal_order = Int(total.focal_order),
                    election_year = Int(total.election_year),
                    case_domain = String(total.case_domain),
                    ideological_universe = String(total.ideological_universe),
                    k = total.k, gap_count = total.gap_count,
                    aggregation_level = configuration.level,
                    component = component,
                    unit_count = length(values),
                    positive_count = count(>(0), values),
                    negative_count = count(<(0), values),
                    gross_positive = Float64(gross_positive),
                    gross_negative_magnitude = Float64(gross_negative),
                    gross_absolute = Float64(gross_absolute),
                    net_component = Float64(net),
                    cancellation_share = gross_absolute == 0 ? 0.0 :
                        1 - Float64(abs(net) / gross_absolute),
                    absolute_hhi = isempty(absolute_shares) ? 0.0 :
                        sum(abs2, absolute_shares),
                    largest_positive_unit = positive.unit,
                    largest_positive_value = Float64(positive.value),
                    largest_positive_share = gross_positive == 0 ? missing :
                        Float64(positive.value / gross_positive),
                    largest_negative_unit = negative.unit,
                    largest_negative_value = Float64(negative.value),
                    largest_negative_share = gross_negative == 0 ? missing :
                        Float64(-negative.value / gross_negative),
                    gross_positive_exact = exact_text(gross_positive),
                    gross_negative_magnitude_exact = exact_text(gross_negative),
                    gross_absolute_exact = exact_text(gross_absolute),
                    net_component_exact = exact_text(net),
                ))
            end
        end
    end
    data = DataFrame(rows)
    sort!(data, [:focal_order, :aggregation_level, :component])
    nrow(data) == nrow(focal.total) * 2 * 3 || error("Each focal case must contain six gross-component rows.")
    return data
end

function build_state_weighting_anatomy(focal)
    rows = NamedTuple[]
    for total in eachrow(focal.total)
        case_id = String(total.case_id)
        selected = focal.state[String.(focal.state.case_id) .== case_id, :]
        values = parse_exact.(selected.b_Cd_exact)
        units = String.(selected.electoral_unit)
        seats = Int.(selected.S_d)
        positive_eight = sum_exact([
            values[index] for index in eachindex(values)
            if values[index] > 0 && seats[index] == 8
        ])
        positive_other = sum_exact([
            values[index] for index in eachindex(values)
            if values[index] > 0 && seats[index] != 8
        ])
        negative_sp = -sum_exact([
            values[index] for index in eachindex(values)
            if values[index] < 0 && units[index] == "SP"
        ])
        negative_other = -sum_exact([
            values[index] for index in eachindex(values)
            if values[index] < 0 && units[index] != "SP"
        ])
        net = positive_eight + positive_other - negative_sp - negative_other
        net == parse_exact(total.B_C_exact) || error(
            "$(case_id): eight-seat/SP state-weighting anatomy does not reproduce B_C.",
        )
        largest_positive = signed_extreme(values, units, true)
        largest_negative = signed_extreme(values, units, false)
        sp_index = only(findall(==("SP"), units))
        push!(rows, (
            case_id = case_id,
            case_display = String(total.case_display),
            case_order = Int(total.case_order),
            focal_order = Int(total.focal_order),
            election_year = Int(total.election_year),
            case_domain = String(total.case_domain),
            ideological_universe = String(total.ideological_universe),
            k = total.k, gap_count = total.gap_count,
            b_positive_eight_seat = Float64(positive_eight),
            b_positive_other = Float64(positive_other),
            b_negative_sp = Float64(negative_sp),
            b_negative_other = Float64(negative_other),
            B_C = Float64(net),
            largest_positive_state = largest_positive.unit,
            largest_positive_b_Cd = Float64(largest_positive.value),
            largest_negative_state = largest_negative.unit,
            largest_negative_b_Cd = Float64(largest_negative.value),
            sp_b_Cd = Float64(values[sp_index]),
            positive_eight_share = positive_eight + positive_other == 0 ? missing :
                Float64(positive_eight / (positive_eight + positive_other)),
            b_positive_eight_seat_exact = exact_text(positive_eight),
            b_positive_other_exact = exact_text(positive_other),
            b_negative_sp_exact = exact_text(negative_sp),
            b_negative_other_exact = exact_text(negative_other),
            B_C_exact = exact_text(net),
        ))
    end
    data = DataFrame(rows)
    sort!(data, :focal_order)
    nrow(data) == nrow(focal.total) || error("State-weighting anatomy must contain one row per focal case.")
    return data
end

function build_selected_party_geography(accounting_by_year::AbstractDict)
    rows = NamedTuple[]
    selected_order = 0
    for year in sort(collect(keys(SELECTED_PARTIES_BY_YEAR)))
        accounting = accounting_by_year[year]
        party_lookup = Dict(String(row.party) => row for row in eachrow(accounting.party))
        for party in SELECTED_PARTIES_BY_YEAR[year]
            selected_order += 1
            haskey(party_lookup, party) || error("Selected party $(year)/$(party) is absent.")
            aggregate = party_lookup[party]
            cells = accounting.panel[String.(accounting.panel.party) .== party, :]
            nrow(cells) == 27 || error("Selected party $(year)/$(party) lacks 27 cells.")
            units = String.(cells.district)
            b_values = Rat.(cells.b_exact)
            a_values = Rat.(cells.a_exact)
            positive_B = sum_exact([value for value in b_values if value > 0])
            negative_B = -sum_exact([value for value in b_values if value < 0])
            largest_positive_B = signed_extreme(b_values, units, true)
            largest_negative_B = signed_extreme(b_values, units, false)
            largest_positive_A = signed_extreme(a_values, units, true)
            largest_negative_A = signed_extreme(a_values, units, false)
            sp_index = only(findall(==("SP"), units))
            positive_eight = sum_exact([
                b_values[index] for index in eachindex(b_values)
                if b_values[index] > 0 && Int(cells.district_seats[index]) == 8
            ])
            positive_B - negative_B == aggregate.B_exact || error(
                "Selected party $(year)/$(party) B geography does not close.",
            )
            push!(rows, (
                selected_order = selected_order,
                election_year = year,
                party = party,
                v_i = Int(aggregate.votes),
                vote_share_pct = 100 * Float64(aggregate.vote_share),
                s_i = Int(aggregate.seats),
                q_i = Float64(aggregate.quota_exact),
                A_i = Float64(aggregate.A_exact),
                B_i = Float64(aggregate.B_exact),
                d_i = Float64(aggregate.d_exact),
                gross_positive_B = Float64(positive_B),
                gross_negative_B_magnitude = Float64(negative_B),
                positive_eight_seat_B = Float64(positive_eight),
                sp_b_id = Float64(b_values[sp_index]),
                largest_positive_B_state = largest_positive_B.unit,
                largest_positive_b_id = Float64(largest_positive_B.value),
                largest_negative_B_state = largest_negative_B.unit,
                largest_negative_b_id = Float64(largest_negative_B.value),
                largest_positive_A_state = largest_positive_A.unit,
                largest_positive_a_id = Float64(largest_positive_A.value),
                largest_negative_A_state = largest_negative_A.unit,
                largest_negative_a_id = Float64(largest_negative_A.value),
                q_i_exact = exact_text(aggregate.quota_exact),
                A_i_exact = exact_text(aggregate.A_exact),
                B_i_exact = exact_text(aggregate.B_exact),
                d_i_exact = exact_text(aggregate.d_exact),
                gross_positive_B_exact = exact_text(positive_B),
                gross_negative_B_magnitude_exact = exact_text(negative_B),
            ))
        end
    end
    data = DataFrame(rows)
    nrow(data) == sum(length, values(SELECTED_PARTIES_BY_YEAR)) || error(
        "Selected party-geography row count changed.",
    )
    return data
end

"""
    build_district_electoral_weight(accounting_by_year)

Construct one audited row per state and election year for the district electoral
weight

    (S_d / V_d) / (S / V),

where the district and national vote totals use the same valid-vote denominator
as the decomposition accounting. Exact-rational values are retained alongside
floating-point columns intended for plotting.
"""
function build_district_electoral_weight(accounting_by_year::AbstractDict)
    rows = NamedTuple[]
    for year in sort(collect(keys(accounting_by_year)))
        accounting = accounting_by_year[year]
        Int(accounting.year) == Int(year) || error(
            "Accounting key $(year) does not match accounting year $(accounting.year).",
        )
        districts = sort(select(accounting.district, :), :district)
        nrow(districts) == 27 || error("$(year): expected 27 electoral units.")

        V = Int(accounting.national_votes)
        S = Int(accounting.national_seats)
        sum(Int.(districts.district_votes)) == V || error(
            "$(year): district valid votes do not reproduce the national denominator.",
        )
        sum(Int.(districts.district_seats)) == S || error(
            "$(year): district seats do not reproduce the Chamber total.",
        )
        national_seats_per_vote = exact_fraction(S, V)

        for district in eachrow(districts)
            V_d = Int(district.district_votes)
            S_d = Int(district.district_seats)
            district_seats_per_vote = exact_fraction(S_d, V_d)
            electoral_weight = district_seats_per_vote / national_seats_per_vote
            share_ratio = exact_fraction(S_d, S) / exact_fraction(V_d, V)
            electoral_weight == share_ratio || error(
                "$(year)/$(district.district): rate and share definitions differ.",
            )
            push!(rows, (
                election_year = Int(year),
                electoral_unit = String(district.district),
                V_d = V_d,
                S_d = S_d,
                V = V,
                S = S,
                district_vote_share = Float64(exact_fraction(V_d, V)),
                district_seat_share = Float64(exact_fraction(S_d, S)),
                district_valid_votes_per_seat = Float64(exact_fraction(V_d, S_d)),
                national_valid_votes_per_seat = Float64(exact_fraction(V, S)),
                district_electoral_weight = Float64(electoral_weight),
                district_electoral_weight_exact = exact_text(electoral_weight),
            ))
        end
    end

    data = DataFrame(rows)
    sort!(data, [:election_year, :electoral_unit])
    expected_rows = 27 * length(accounting_by_year)
    nrow(data) == expected_rows || error(
        "District electoral-weight data must contain $(expected_rows) rows.",
    )
    nrow(unique(select(data, :election_year, :electoral_unit))) == nrow(data) || error(
        "District electoral-weight data contain duplicate state-year rows.",
    )
    return data
end
function integration_checks(integration; accounting_years = (2014, 2018, 2022))
    Set(Int.(integration.district_electoral_weight.election_year)) == Set(Int.(collect(accounting_years))) || error("District electoral-weight election coverage differs from the fixed accounting panels")
    baseline_n = nrow(integration.baseline.total)
    focal_n = nrow(integration.focal.total)
    minimal_n = sum(coalesce.(integration.baseline.total.minimal_inversion, false))
    expected = (
        ("focal_state_rows", nrow(integration.focal.state), focal_n * 27),
        ("gross_component_rows", nrow(integration.gross_components), focal_n * 6),
        ("state_weighting_rows", nrow(integration.state_weighting_anatomy), focal_n),
        ("selected_party_rows", nrow(integration.selected_party_geography), sum(length, values(SELECTED_PARTIES_BY_YEAR))),
        ("district_electoral_weight_rows", nrow(integration.district_electoral_weight), 27 * length(accounting_years)),
        ("minimal_ideological_cases", nrow(integration.minimal_ideological), minimal_n),
        ("coalition_party_contribution_rows", nrow(integration.party_contributions.contributions), nrow(integration.baseline.party)),
        ("coalition_party_contribution_cases", nrow(integration.party_contributions.summary), baseline_n),
        ("coalition_party_contribution_focal_cases", nrow(integration.party_contributions.focal_summary), sum(integration.baseline.total.case_domain .== "cabinet") + minimal_n),
        ("coalition_party_contribution_checks", nrow(integration.party_contributions.checks), baseline_n),
    )
    rows = NamedTuple[]
    for (check_name, actual, target) in expected
        actual == target || error("$(check_name): expected $(target), found $(actual).")
        push!(rows, (
            scope = "accounting_integration",
            check_name = check_name,
            actual = string(actual),
            expected = string(target),
            status = "PASS",
        ))
    end
    push!(rows, (
        scope = "accounting_integration",
        check_name = "state_weighting_gross_identity",
        actual = "$(focal_n) exact closures",
        expected = "$(focal_n) exact closures",
        status = "PASS",
    ))
    all(integration.party_contributions.checks.all_checks_pass) || error(
        "A coalition-party contribution validation did not pass.",
    )
    push!(rows, (
        scope = "accounting_integration",
        check_name = "coalition_party_contribution_validations",
        actual = "$(baseline_n) complete case audits",
        expected = "$(baseline_n) complete case audits",
        status = "PASS",
    ))
    return DataFrame(rows)
end

"""
    build_accounting_integration(registry, accounting_by_year)

Build the manuscript-facing accounting layer from the same exact election
panels and audited inversion registry used by the standalone intermediate
report. It retains all registered baseline totals and selected focal vectors.
"""
function build_accounting_integration(
    registry::DataFrame,
    accounting_by_year::AbstractDict,
)
    baseline, by_id = baseline_case_outputs(registry, accounting_by_year)
    party_contributions = build_coalition_party_contribution_diagnostics(baseline, registry)
    focal = build_focal_outputs(registry, accounting_by_year, by_id)
    gross_components = gross_component_summary(focal)
    state_weighting_anatomy = build_state_weighting_anatomy(focal)
    selected_party_geography = build_selected_party_geography(accounting_by_year)
    district_electoral_weight = build_district_electoral_weight(accounting_by_year)
    minimal_ideological = baseline.total[
        coalesce.(baseline.total.minimal_inversion, false),
        :,
    ]
    sort!(
        minimal_ideological,
        [:election_year, :ideology_start_index, :ideology_end_index],
    )

    integration = (
        baseline = baseline,
        focal = focal,
        gross_components = gross_components,
        state_weighting_anatomy = state_weighting_anatomy,
        selected_party_geography = selected_party_geography,
        district_electoral_weight = district_electoral_weight,
        minimal_ideological = minimal_ideological,
        party_contributions = party_contributions,
    )
    return merge(integration, (checks = integration_checks(integration; accounting_years = keys(accounting_by_year)),))
end
latex_escape(value) = replace(
    string(value),
    "\\" => "\\textbackslash{}",
    "&" => "\\&",
    "%" => "\\%",
    "#" => "\\#",
    "_" => "\\_",
    "{" => "\\{",
    "}" => "\\}",
)
fmt2(value) = @sprintf("%.2f", Float64(value))
fmtpct(value) = @sprintf("%.2f", Float64(value))

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

function party_contribution_closure_preserving_display(d_C, gross_positive)
    d_milli = round(Int, 1000 * Float64(d_C))
    positive_milli = round(Int, 1000 * Float64(gross_positive))
    negative_milli = positive_milli - d_milli
    return (
        d_C = @sprintf("%.3f", d_milli / 1000),
        gross_positive = @sprintf("%.3f", positive_milli / 1000),
        gross_negative = @sprintf("%.3f", negative_milli / 1000),
    )
end
fmtshare(value) = @sprintf("%.0f", 100 * Float64(value)) * "\\%"

function write_text(path::AbstractString, contents::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, contents)
        endswith(contents, "\n") || write(io, "\n")
    end
    return path
end

function sha256_file(path::AbstractString)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end





function contributor_entry(row, party_field::Symbol, value_field::Symbol)
    party = row[party_field]
    value = row[value_field]
    (ismissing(party) || ismissing(value)) && return "---"
    return "$(latex_escape(party)) ($(fmt2(value)))"
end

function two_contributor_entries(
    row,
    first_party::Symbol,
    first_value::Symbol,
    second_party::Symbol,
    second_value::Symbol,
)
    first_entry = contributor_entry(row, first_party, first_value)
    second_entry = contributor_entry(row, second_party, second_value)
    second_entry == "---" && return first_entry
    return "$(first_entry); $(second_entry)"
end



include("CabinetDistrictTable.jl")
include("PartyComponentTable.jl")

"""
    write_accounting_integration_outputs(output_root, integration)

Write machine-readable focal, concentration, and geography outputs plus the
CSV-derived LaTeX assets used by the manuscript. Returns manifest rows
that can be merged into the paper artifact manifest by the calling runner.
"""
function write_accounting_integration_outputs(
    output_root::AbstractString,
    integration,
)
    raw_dir = joinpath(output_root, "raw")
    table_dir = joinpath(output_root, "tables")
    figure_dir = joinpath(output_root, "figure_data")
    latex_dir = joinpath(output_root, "latex")
    audit_dir = joinpath(output_root, "audit")
    foreach(mkpath, (raw_dir, table_dir, figure_dir, latex_dir, audit_dir))

    artifacts = NamedTuple[]
    reloaded = Dict{String,DataFrame}()
    function record_csv(relative_path, data, artifact_type, description)
        path = joinpath(output_root, relative_path)
        mkpath(dirname(path))
        CSV.write(path, data)
        roundtrip = CSV.read(path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
        nrow(roundtrip) == nrow(data) || error(
            "CSV roundtrip row mismatch: $(relative_path).",
        )
        length(names(roundtrip)) == length(names(data)) || error(
            "CSV roundtrip column mismatch: $(relative_path).",
        )
        reloaded[relative_path] = roundtrip
        push!(artifacts, (
            path = replace(relative_path, '\\' => '/'),
            artifact_type = artifact_type,
            description = description,
            rows = nrow(roundtrip),
            columns = length(names(roundtrip)),
            sha256 = sha256_file(path),
        ))
        return roundtrip
    end

    record_csv(
        "raw/accounting_all_inversion_decomposition.csv",
        integration.baseline.total,
        "raw",
        "Exact-audited accounting totals for all registered inversion cases.",
    )
    record_csv(
        "raw/coalition_party_contributions.csv",
        integration.party_contributions.contributions,
        "raw",
        "Canonical complete case-party contribution vectors for all cabinet and ideological inversions.",
    )
    record_csv(
        "raw/coalition_party_contribution_summary.csv",
        integration.party_contributions.summary,
        "raw",
        "Case-level gross, net, concentration, and top-two party contribution diagnostics.",
    )
    record_csv(
        "raw/coalition_party_contribution_named_aggregates.csv",
        integration.party_contributions.named_aggregates,
        "raw",
        "Named exact party aggregation used for the PP-PL substantive diagnostic.",
    )
    record_csv(
        "raw/accounting_focal_case_decomposition.csv",
        integration.focal.total,
        "raw",
        "Selected focal cabinet and ideological accounting vectors.",
    )
    record_csv(
        "raw/accounting_focal_party_contributions.csv",
        integration.focal.party,
        "raw",
        "Complete member-party vectors for the selected focal cases.",
    )
    record_csv(
        "raw/accounting_focal_state_contributions.csv",
        integration.focal.state,
        "raw",
        "Complete 27-state vectors for the selected focal cases.",
    )
    record_csv(
        "raw/accounting_focal_party_state_contributions.csv",
        integration.focal.cells,
        "raw",
        "Complete member-party-by-state cells for the selected focal cases.",
    )
    record_csv(
        "raw/accounting_gross_component_concentration.csv",
        integration.gross_components,
        "raw",
        "Gross positive, negative, cancellation, and concentration diagnostics.",
    )
    record_csv(
        "raw/accounting_selected_party_geography.csv",
        integration.selected_party_geography,
        "raw",
        "Selected party differentials and state-level accounting geography.",
    )
    record_csv(
        "raw/accounting_minimal_ideological_decomposition.csv",
        integration.minimal_ideological,
        "raw",
        "All primary minimal connected ideological inversion decompositions.",
    )
    record_csv(
        "figure_data/accounting_state_weighting_anatomy.csv",
        integration.state_weighting_anatomy,
        "figure_data",
        "Seven-case gross positive and negative state-weighting anatomy.",
    )
    record_csv(
        "figure_data/accounting_district_electoral_weight.csv",
        integration.district_electoral_weight,
        "figure_data",
        "State-year district electoral weights derived from audited valid votes and seats.",
    )
    record_csv(
        "audit/accounting_integration_checks.csv",
        integration.checks,
        "audit",
        "Cardinality, registry, identity, and generation checks for manuscript integration.",
    )
    record_csv(
        "audit/coalition_party_contribution_checks.csv",
        integration.party_contributions.checks,
        "audit",
        "Per-case vote, seat, exact differential, source-regression, and inversion checks.",
    )

    focal_table = select(integration.focal.total, :)
    gross_table = integration.gross_components[
        in.(String.(integration.gross_components.component), Ref(Set(["A", "B"]))),
        :,
    ]
    party_table = select(integration.selected_party_geography, :)
    minimal_table = select(integration.minimal_ideological, :)
    contribution_table = select(integration.party_contributions.focal_summary, :)
    record_csv(
        "tables/table_accounting_focal_cases.csv",
        focal_table,
        "table",
        "Manuscript table source for selected focal accounting vectors.",
    )
    record_csv(
        "tables/table_accounting_gross_components.csv",
        gross_table,
        "table",
        "Appendix table source for gross focal accounting components.",
    )
    record_csv(
        "tables/table_accounting_selected_party_geography.csv",
        party_table,
        "table",
        "Appendix table source for selected party state geography.",
    )
    record_csv(
        "tables/table_accounting_minimal_ideological.csv",
        minimal_table,
        "table",
        "Manuscript table source for all endpoint-minimal ideological decompositions.",
    )
    record_csv(
        "tables/table_coalition_party_contributions.csv",
        contribution_table,
        "table",
        "Appendix table source for selected focal coalition-party contribution vectors.",
    )

    component_table, component_checks = party_component_extremes(
        reloaded["raw/coalition_party_contributions.csv"],
        reloaded["tables/table_coalition_party_contributions.csv"],
    )
    record_csv("tables/table_coalition_party_component_extremes.csv", component_table, "table",
        "Largest signed member-party A_i/B_i contributions for the existing focal appendix cases.")
    record_csv("audit/coalition_party_component_checks.csv", component_checks, "audit",
        "Exact and numerical closure audits of the focal member-party component vectors.")

    district_table = cabinet_district_concentration(integration.focal.state)
    record_csv("tables/table_cabinet_district_concentration.csv", district_table, "table",
        "Exact district concentration for inverted cabinet vectors; shared table/prose source.")
    return artifacts
end

end # module AccountingIntegration
