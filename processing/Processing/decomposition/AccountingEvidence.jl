module AccountingEvidence

using CSV
using DataFrames
using Printf
using SHA
using Statistics
using Dates
using JSON3

import ..CoalitionDecomposition

const CD = CoalitionDecomposition

export EXPECTED_PARTY_DISTRICT_ROWS,
       build_full_accounting_outputs,
       build_inversion_case_registry,
       decompose_case_registry,
       build_case_rankings,
       build_party_size_diagnostics!,
       validate_party_size_regressions,
       write_party_size_diagnostic_outputs,
       write_accounting_evidence_outputs

const EXPECTED_PARTIES_BY_YEAR = Dict(2014 => 32, 2018 => 35, 2022 => 32)
const EXPECTED_PARTY_DISTRICT_ROWS = sum(27 * value for value in values(EXPECTED_PARTIES_BY_YEAR))

require(condition::Bool, message::AbstractString) = condition ? true : error(message)
fmt2(value) = @sprintf("%.2f", Float64(value))
fmt3(value) = @sprintf("%.3f", Float64(value))
fmt4(value) = @sprintf("%.4f", Float64(value))
fmtpct(value) = @sprintf("%.2f", 100 * Float64(value))
exact_text(value) = string(numerator(value), "//", denominator(value))

function ordered_parties(value)
    parties = String.(filter(!isempty, strip.(split(String(value), ","))))
    length(parties) == length(unique(parties)) || error(
        "Coalition contains duplicate party labels: $(value)",
    )
    return parties
end

function require_approx(left, right, label)
    CD.accounting_isapprox(left, right) || error(
        "$(label): values differ (left=$(left), right=$(right), " *
        "atol=$(CD.ACCOUNTING_ATOL), rtol=$(CD.ACCOUNTING_RTOL)).",
    )
    return true
end

function sign_pattern(A, B)
    A > 0 && B > 0 && return "A+, B+: reinforcing accounting components"
    A > 0 && B < 0 && return "A+, B-: B offsets part of A"
    A < 0 && B > 0 && return "A-, B+: B more than offsets A"
    A < 0 && B < 0 && return "A-, B-: both components negative"
    A == 0 && return "A=0"
    return "B=0"
end

"""
    build_full_accounting_outputs(accounting_by_year)

Persistable views of the exact party-by-district panels already produced by
`build_year_accounting`. The returned cell table includes every explicit zero
cell. Exact rational strings accompany decimal columns used by tables.
"""
function build_full_accounting_outputs(accounting_by_year::AbstractDict)
    cell_rows = NamedTuple[]
    party_rows = NamedTuple[]
    district_rows = NamedTuple[]
    validation_rows = NamedTuple[]

    for year in sort(collect(keys(accounting_by_year)))
        accounting = accounting_by_year[year]
        expected_parties = EXPECTED_PARTIES_BY_YEAR[Int(year)]
        nrow(accounting.party) == expected_parties || error(
            "$(year): expected $(expected_parties) parties, found $(nrow(accounting.party)).",
        )
        nrow(accounting.panel) == 27 * expected_parties || error(
            "$(year): complete panel has the wrong number of cells.",
        )
        length(unique(String.(accounting.panel.district))) == 27 || error(
            "$(year): complete panel does not contain 27 electoral units.",
        )

        party_lookup = Dict(String(row.party) => row for row in eachrow(accounting.party))
        for row in eachrow(accounting.panel)
            aggregate = party_lookup[String(row.party)]
            cell_d_exact = row.a_exact + row.b_exact
            expected_cell_d = CD.exact_fraction(row.seats, 1) - row.national_quota_contribution_exact
            cell_d_exact == expected_cell_d || error(
                "$(year)/$(row.district)/$(row.party): a_id + b_id != cell differential.",
            )
            row.b_exact == row.b_factored_exact || error(
                "$(year)/$(row.district)/$(row.party): defining and factored b_id differ.",
            )
            push!(cell_rows, (
                election_year = Int(year),
                electoral_unit = String(row.district),
                party = String(row.party),
                v_id = Int(row.votes),
                V_d = Int(row.district_votes),
                district_party_vote_share = row.votes / row.district_votes,
                s_id = Int(row.seats),
                S_d = Int(row.district_seats),
                district_party_seat_share = row.seats / row.district_seats,
                v_i = Int(aggregate.votes),
                V = Int(accounting.national_votes),
                national_party_vote_share = Float64(aggregate.vote_share),
                national_cell_vote_share = row.votes / accounting.national_votes,
                s_i = Int(aggregate.seats),
                S = Int(accounting.national_seats),
                national_party_seat_share = Float64(aggregate.seat_share),
                district_vote_weight = row.district_votes / accounting.national_votes,
                district_seat_weight = row.district_seats / accounting.national_seats,
                district_weight_gap = row.district_seats / accounting.national_seats -
                    row.district_votes / accounting.national_votes,
                within_district_quota = Float64(row.within_quota_exact),
                national_quota_contribution = Float64(row.national_quota_contribution_exact),
                a_id = Float64(row.a_exact),
                b_id = Float64(row.b_exact),
                b_id_factored = Float64(row.b_factored_exact),
                b_crosscheck_residual = Float64(row.b_exact - row.b_factored_exact),
                d_id = Float64(cell_d_exact),
                q_i = Float64(aggregate.quota_exact),
                R_i = aggregate.R_exact === missing ? missing : Float64(aggregate.R_exact),
                d_i = Float64(aggregate.d_exact),
                A_i = Float64(aggregate.A_exact),
                B_i = Float64(aggregate.B_exact),
                within_district_quota_exact = exact_text(row.within_quota_exact),
                national_quota_contribution_exact = exact_text(row.national_quota_contribution_exact),
                a_id_exact = exact_text(row.a_exact),
                b_id_exact = exact_text(row.b_exact),
                b_id_factored_exact = exact_text(row.b_factored_exact),
                d_id_exact = exact_text(cell_d_exact),
                accounting_qualification = CD.qualification_for_year(Int(year)),
            ))
        end

        for row in eachrow(accounting.party)
            residual = row.A_exact + row.B_exact - row.d_exact
            residual == 0 || error("$(year)/$(row.party): A_i + B_i != d_i exactly.")
            push!(party_rows, (
                election_year = Int(year),
                party = String(row.party),
                v_i = Int(row.votes),
                V = Int(accounting.national_votes),
                vote_share = Float64(row.vote_share),
                s_i = Int(row.seats),
                S = Int(accounting.national_seats),
                seat_share = Float64(row.seat_share),
                q_i = Float64(row.quota_exact),
                R_i = row.R_exact === missing ? missing : Float64(row.R_exact),
                d_i = Float64(row.d_exact),
                A_i = Float64(row.A_exact),
                B_i = Float64(row.B_exact),
                A_plus_B_residual = Float64(residual),
                q_i_exact = exact_text(row.quota_exact),
                d_i_exact = exact_text(row.d_exact),
                A_i_exact = exact_text(row.A_exact),
                B_i_exact = exact_text(row.B_exact),
                accounting_qualification = CD.qualification_for_year(Int(year)),
            ))
        end

        for group in groupby(accounting.panel, :district)
            district = String(first(group.district))
            V_d = Int(first(group.district_votes))
            S_d = Int(first(group.district_seats))
            sum_a = sum(group.a_exact)
            sum_b = sum(group.b_exact)
            expected_b = CD.exact_fraction(S_d, 1) -
                CD.Processing.proportional_quota(V_d, accounting.national_votes, accounting.national_seats)
            sum_a == 0 || error("$(year)/$(district): sum_i a_id != 0.")
            sum_b == expected_b || error("$(year)/$(district): sum_i b_id closure failed.")
            push!(district_rows, (
                election_year = Int(year),
                electoral_unit = district,
                V_d = V_d,
                S_d = S_d,
                V = Int(accounting.national_votes),
                S = Int(accounting.national_seats),
                district_vote_weight = V_d / accounting.national_votes,
                district_seat_weight = S_d / accounting.national_seats,
                district_weight_gap = S_d / accounting.national_seats -
                    V_d / accounting.national_votes,
                seat_equivalent_weight_gap = Float64(expected_b),
                valid_votes_per_seat = V_d / S_d,
                sum_a_id = Float64(sum_a),
                sum_b_id = Float64(sum_b),
                expected_sum_b_id = Float64(expected_b),
                b_closure_residual = Float64(sum_b - expected_b),
                seat_equivalent_weight_gap_exact = exact_text(expected_b),
            ))
        end

        for (check_name, exact_value) in (
            ("complete-system sum_i A_i = 0", sum(accounting.party.A_exact)),
            ("complete-system sum_i B_i = 0", sum(accounting.party.B_exact)),
            ("complete-system sum_i d_i = 0", sum(accounting.party.d_exact)),
        )
            exact_value == 0 || error("$(year): $(check_name) failed.")
            push!(validation_rows, (
                scope = "year",
                case_id = missing,
                election_year = Int(year),
                check_name = check_name,
                exact_pass = true,
                floating_residual = Float64(exact_value),
                atol = CD.ACCOUNTING_ATOL,
                rtol = CD.ACCOUNTING_RTOL,
                status = "PASS",
            ))
        end
    end

    cells = DataFrame(cell_rows)
    parties = DataFrame(party_rows)
    districts = DataFrame(district_rows)
    validations = DataFrame(validation_rows)
    sort!(cells, [:election_year, :electoral_unit, :party])
    sort!(parties, [:election_year, :party])
    sort!(districts, [:election_year, :electoral_unit])
    nrow(cells) == EXPECTED_PARTY_DISTRICT_ROWS || error(
        "Complete all-year party-district panel has $(nrow(cells)) rows, not $(EXPECTED_PARTY_DISTRICT_ROWS).",
    )
    nrow(parties) == sum(values(EXPECTED_PARTIES_BY_YEAR)) || error(
        "Complete party accounting output has the wrong row count.",
    )
    nrow(districts) == 81 || error("Complete district accounting output must contain 81 rows.")
    return (cells = cells, parties = parties, districts = districts, validations = validations)
end

function build_inversion_case_registry(
    coalition_periods::DataFrame,
    ideological_intervals::DataFrame,
    accounting_by_year::AbstractDict,
)
    rows = NamedTuple[]
    cabinets = coalition_periods[coalesce.(coalition_periods.coalition_inversion, false), :]
    cabinet_keys = [
        (Int(row.election_year), String(row.cabinet_period)) for row in eachrow(cabinets)
    ]
    length(unique(cabinet_keys)) == nrow(cabinets) || error("Duplicate cabinet inversion registry rows")
    for (case_order, row) in enumerate(eachrow(cabinets))
        year = Int(row.election_year)
        parties = ordered_parties(row.coalition_parties)
        push!(rows, (
            case_id = "cabinet/$(row.coalition_id)",
            source_case_id = String(row.coalition_id),
            case_domain = "cabinet",
            ideological_universe = "not_applicable",
            k = missing,
            gap_count = missing,
            case_order = case_order,
            election_year = year,
            case_label = String(row.cabinet_period),
            cabinet_period = String(row.cabinet_period),
            source_periods = String(row.source_periods),
            period_start = row.period_start,
            period_end = row.period_end,
            period_days = Int(row.period_days),
            ideology_start_index = missing,
            ideology_end_index = missing,
            start_party = missing,
            end_party = missing,
            coalition_parties = String(row.coalition_parties),
            coalition_party_count = length(parties),
            minimal_inversion = missing,
            minimal_status = "not applicable",
            observed_coalition = true,
            synthetic_ideological_interval = false,
            v_C = Int(row.v_C),
            V = Int(row.V),
            vote_share = Float64(row.vote_share),
            s_C = Int(row.s_C),
            S = Int(row.S),
            seat_share = Float64(row.seat_share),
            q_C = Float64(row.q_C),
            d_C = Float64(row.d_C),
            r_C = Float64(row.r_C),
            R_C = Float64(row.R_C),
            source_registry = "Distinct translated cabinet party sets from pinned V5 chronology",
        ))
    end

    ideological = ideological_intervals[Bool.(ideological_intervals.coalition_inversion), :]
    for (case_order, row) in enumerate(eachrow(ideological))
        year = Int(row.election_year)
        accounting = accounting_by_year[year]
        parties = ordered_parties(row.parties)
        Int(row.interval_size) == length(parties) || error(
            "$(year)/$(row.start_index)-$(row.end_index): interval size differs from membership.",
        )
        minimal = Bool(row.minimal_connected_inversion)
        push!(rows, (
            case_id = @sprintf("ideological/%d/%02d-%02d", year, row.start_index, row.end_index),
            source_case_id = "$(year)/$(row.start_index)-$(row.end_index)",
            case_domain = "ideological",
            ideological_universe = String(row.ideological_universe),
            k = 0,
            gap_count = 0,
            case_order = case_order,
            election_year = year,
            case_label = "$(row.start_index)-$(row.end_index) $(row.start_party)-$(row.end_party)",
            cabinet_period = missing,
            source_periods = missing,
            period_start = missing,
            period_end = missing,
            period_days = missing,
            ideology_start_index = Int(row.start_index),
            ideology_end_index = Int(row.end_index),
            start_party = String(row.start_party),
            end_party = String(row.end_party),
            coalition_parties = String(row.parties),
            coalition_party_count = length(parties),
            minimal_inversion = minimal,
            minimal_status = minimal ? "endpoint-minimal" : "nonminimal",
            observed_coalition = false,
            synthetic_ideological_interval = true,
            v_C = Int(row.votes),
            V = Int(row.national_vote_total),
            vote_share = Float64(row.vote_share),
            s_C = Int(row.seats),
            S = Int(accounting.national_seats),
            seat_share = Float64(row.seat_share),
            q_C = Float64(row.quota),
            d_C = Float64(row.seat_diff),
            r_C = Float64(row.required_diff),
            R_C = Float64(row.representation_ratio),
            source_registry = "validated contiguous ideological intervals",
        ))
    end

    registry = DataFrame(rows)
    registry[!, :composition_equivalence_group] = [
        "$(row.election_year):" * join(sort(ordered_parties(row.coalition_parties)), "|") for
        row in eachrow(registry)
    ]
    group_sizes = combine(
        groupby(registry, :composition_equivalence_group),
        nrow => :composition_equivalence_count,
    )
    registry = leftjoin(registry, group_sizes; on = :composition_equivalence_group)
    registry[!, :compositionally_repeated] = registry.composition_equivalence_count .> 1
    sort!(registry, [:case_domain, :election_year, :case_order])

    nrow(registry) == nrow(cabinets) + nrow(ideological) || error("Combined registry cardinality mismatch.")
    sum(registry.case_domain .== "cabinet") == nrow(cabinets) || error("Combined registry lost cabinet cases.")
    all(registry.vote_share .< 0.5) && all(registry.s_C .>= 257) || error("Registry contains a non-inversion.")
    # Nonadjacent returns to the same party set remain separate observations.
    # composition_equivalence_count records repetition without deleting chronology.
    return registry
end

function case_metadata(row)
    return (
        case_id = String(row.case_id),
        source_case_id = String(row.source_case_id),
        case_domain = String(row.case_domain),
        ideological_universe = String(row.ideological_universe),
        k = row.k,
        gap_count = row.gap_count,
        case_order = Int(row.case_order),
        election_year = Int(row.election_year),
        case_label = String(row.case_label),
        cabinet_period = row.cabinet_period,
        source_periods = row.source_periods,
        period_start = row.period_start,
        period_end = row.period_end,
        period_days = row.period_days,
        ideology_start_index = row.ideology_start_index,
        ideology_end_index = row.ideology_end_index,
        start_party = row.start_party,
        end_party = row.end_party,
        coalition_parties = String(row.coalition_parties),
        coalition_party_count = Int(row.coalition_party_count),
        minimal_inversion = row.minimal_inversion,
        minimal_status = String(row.minimal_status),
        observed_coalition = Bool(row.observed_coalition),
        synthetic_ideological_interval = Bool(row.synthetic_ideological_interval),
        composition_equivalence_group = String(row.composition_equivalence_group),
        composition_equivalence_count = Int(row.composition_equivalence_count),
        compositionally_repeated = Bool(row.compositionally_repeated),
    )
end

"""
    decompose_case_registry(registry, accounting_by_year)

Apply the same exact party/district accounting to all identified cabinet and all
registered ideological inversion coalitions. Ideological membership is read
directly from the validated interval output; no coalition is reconstructed by
hand.
"""
function decompose_case_registry(registry::DataFrame, accounting_by_year::AbstractDict)
    decomposition_rows = NamedTuple[]
    party_rows = NamedTuple[]
    district_rows = NamedTuple[]
    party_district_rows = NamedTuple[]
    validation_rows = NamedTuple[]

    for case in eachrow(registry)
        metadata = case_metadata(case)
        year = Int(case.election_year)
        accounting = accounting_by_year[year]
        ordered = ordered_parties(case.coalition_parties)
        values_C = CD.coalition_accounting(accounting, ordered; include_districts=true)
        values_C.status.coalition_inversion || error("$(case.case_id): registry contains a non-inversion.")
        party_lookup = Dict(String(row.party) => row for row in eachrow(values_C.members))
        member_rows = [party_lookup[party] for party in ordered]
        v_C, s_C = values_C.votes, values_C.seats
        q_exact, d_exact, r_exact = values_C.q, values_C.d, values_C.r
        R_value = s_C / Float64(q_exact)

        v_C == Int(case.v_C) || error("$(case.case_id): coalition votes differ from source registry.")
        s_C == Int(case.s_C) || error("$(case.case_id): coalition seats differ from source registry.")
        accounting.national_votes == Int(case.V) || error(
            "$(case.case_id): national vote denominator differs from source registry.",
        )
        accounting.national_seats == Int(case.S) || error(
            "$(case.case_id): national seat total differs from source registry.",
        )
        require_approx(v_C / accounting.national_votes, case.vote_share, "$(case.case_id) vote share")
        require_approx(s_C / accounting.national_seats, case.seat_share, "$(case.case_id) seat share")
        require_approx(q_exact, case.q_C, "$(case.case_id) q_C")
        require_approx(d_exact, case.d_C, "$(case.case_id) d_C")
        require_approx(r_exact, case.r_C, "$(case.case_id) r_C")
        require_approx(R_value, case.R_C, "$(case.case_id) R_C")

        A_exact, B_exact = values_C.A, values_C.B
        party_d_exact = sum(row.d_exact for row in member_rows)
        case_district_A = CD.Rat(0)
        case_district_B = CD.Rat(0)
        for values in values_C.districts
            district = values.district
            case_district_A += values.a_exact
            case_district_B += values.b_exact
            push!(district_rows, merge(metadata, (
                electoral_unit = district,
                v_Cd = values.v_Cd,
                V_d = values.V_d,
                district_coalition_vote_share = values.v_Cd / values.V_d,
                s_Cd = values.s_Cd,
                S_d = values.S_d,
                district_coalition_seat_share = values.s_Cd / values.S_d,
                within_district_quota = Float64(values.within_quota_exact),
                national_quota_contribution = Float64(values.national_contribution_exact),
                a_Cd = Float64(values.a_exact),
                b_Cd = Float64(values.b_exact),
                b_Cd_factored = Float64(values.b_factored_exact),
                b_crosscheck_residual = Float64(values.b_exact - values.b_factored_exact),
                d_Cd = Float64(values.a_exact + values.b_exact),
                a_Cd_exact = exact_text(values.a_exact),
                b_Cd_exact = exact_text(values.b_exact),
                d_Cd_exact = exact_text(values.a_exact + values.b_exact),
            )))
        end
        case_district_A == A_exact || error("$(case.case_id): sum_d a_Cd != A_C exactly.")
        case_district_B == B_exact || error("$(case.case_id): sum_d b_Cd != B_C exactly.")

        linked_A = CD.Rat(0)
        linked_B = CD.Rat(0)
        for (party_order, party_name) in enumerate(ordered)
            member = party_lookup[party_name]
            push!(party_rows, merge(metadata, (
                coalition_party_order = party_order,
                party = party_name,
                v_i = Int(member.votes),
                V = Int(accounting.national_votes),
                vote_share = Float64(member.vote_share),
                s_i = Int(member.seats),
                S = Int(accounting.national_seats),
                seat_share = Float64(member.seat_share),
                q_i = Float64(member.quota_exact),
                R_i = member.R_exact === missing ? missing : Float64(member.R_exact),
                d_i = Float64(member.d_exact),
                A_i = Float64(member.A_exact),
                B_i = Float64(member.B_exact),
                A_plus_B_residual = Float64(member.A_exact + member.B_exact - member.d_exact),
                q_times_R_minus_1 = member.R_exact === missing ? missing :
                    Float64(member.quota_exact * (member.R_exact - CD.exact_fraction(1, 1))),
                accounting_qualification = CD.qualification_for_year(year),
            )))

            member_cells = accounting.panel[accounting.panel.party .== party_name, :]
            nrow(member_cells) == 27 || error("$(case.case_id)/$(party_name): expected 27 cells.")
            for cell in eachrow(member_cells)
                d_cell_exact = cell.a_exact + cell.b_exact
                linked_A += cell.a_exact
                linked_B += cell.b_exact
                push!(party_district_rows, merge(metadata, (
                    coalition_party_order = party_order,
                    party = party_name,
                    electoral_unit = String(cell.district),
                    v_id = Int(cell.votes),
                    V_d = Int(cell.district_votes),
                    district_party_vote_share = cell.votes / cell.district_votes,
                    s_id = Int(cell.seats),
                    S_d = Int(cell.district_seats),
                    district_party_seat_share = cell.seats / cell.district_seats,
                    district_vote_weight = cell.district_votes / accounting.national_votes,
                    district_seat_weight = cell.district_seats / accounting.national_seats,
                    district_weight_gap = cell.district_seats / accounting.national_seats -
                        cell.district_votes / accounting.national_votes,
                    within_district_quota = Float64(cell.within_quota_exact),
                    national_quota_contribution = Float64(cell.national_quota_contribution_exact),
                    a_id = Float64(cell.a_exact),
                    b_id = Float64(cell.b_exact),
                    b_id_factored = Float64(cell.b_factored_exact),
                    b_crosscheck_residual = Float64(cell.b_exact - cell.b_factored_exact),
                    d_id = Float64(d_cell_exact),
                    a_id_exact = exact_text(cell.a_exact),
                    b_id_exact = exact_text(cell.b_exact),
                    d_id_exact = exact_text(d_cell_exact),
                    accounting_qualification = CD.qualification_for_year(year),
                )))
            end
        end
        linked_A == A_exact || error("$(case.case_id): linked member cells do not sum to A_C.")
        linked_B == B_exact || error("$(case.case_id): linked member cells do not sum to B_C.")

        push!(decomposition_rows, merge(metadata, (
            v_C = v_C,
            V = Int(accounting.national_votes),
            vote_share = v_C / accounting.national_votes,
            vote_share_pct = 100 * v_C / accounting.national_votes,
            s_C = s_C,
            S = Int(accounting.national_seats),
            seat_share = s_C / accounting.national_seats,
            q_C = Float64(q_exact),
            d_C = Float64(d_exact),
            r_C = Float64(r_exact),
            R_C = Float64(R_value),
            A_C = Float64(A_exact),
            B_C = Float64(B_exact),
            A_share_of_d_C = Float64(A_exact / d_exact),
            B_share_of_d_C = Float64(B_exact / d_exact),
            dominant_absolute_component = abs(A_exact) >= abs(B_exact) ? "A_C" : "B_C",
            component_sign_pattern = sign_pattern(A_exact, B_exact),
            A_plus_B_residual = Float64(A_exact + B_exact - d_exact),
            party_d_residual = Float64(party_d_exact - d_exact),
            district_A_residual = Float64(case_district_A - A_exact),
            district_B_residual = Float64(case_district_B - B_exact),
            linked_cell_A_residual = Float64(linked_A - A_exact),
            linked_cell_B_residual = Float64(linked_B - B_exact),
            q_C_exact = exact_text(q_exact),
            d_C_exact = exact_text(d_exact),
            r_C_exact = exact_text(r_exact),
            A_C_exact = exact_text(A_exact),
            B_C_exact = exact_text(B_exact),
            accounting_qualification = CD.qualification_for_year(year),
            interpretation = "accounting identity; B combines district seat weights, valid-vote weights, and coalition vote geography",
        )))

        checks = (
            ("A_C + B_C = d_C", A_exact + B_exact - d_exact),
            ("sum_i d_i = d_C", party_d_exact - d_exact),
            ("sum_i A_i = A_C", sum(row.A_exact for row in member_rows) - A_exact),
            ("sum_i B_i = B_C", sum(row.B_exact for row in member_rows) - B_exact),
            ("sum_d a_Cd = A_C", case_district_A - A_exact),
            ("sum_d b_Cd = B_C", case_district_B - B_exact),
            ("sum_id a_id = A_C", linked_A - A_exact),
            ("sum_id b_id = B_C", linked_B - B_exact),
        )
        for (check_name, residual) in checks
            residual == 0 || error("$(case.case_id): $(check_name) failed exactly.")
            push!(validation_rows, (
                scope = "case",
                case_id = String(case.case_id),
                election_year = year,
                check_name = check_name,
                exact_pass = true,
                floating_residual = Float64(residual),
                atol = CD.ACCOUNTING_ATOL,
                rtol = CD.ACCOUNTING_RTOL,
                status = "PASS",
            ))
        end
    end

    decomposition = DataFrame(decomposition_rows)
    party_contributions = DataFrame(party_rows)
    district_contributions = DataFrame(district_rows)
    party_district_contributions = DataFrame(party_district_rows)
    validations = DataFrame(validation_rows)
    sort!(decomposition, [:case_domain, :election_year, :case_order])
    sort!(party_contributions, [:case_domain, :election_year, :case_order, :coalition_party_order])
    sort!(district_contributions, [:case_domain, :election_year, :case_order, :electoral_unit])
    sort!(party_district_contributions,
        [:case_domain, :election_year, :case_order, :coalition_party_order, :electoral_unit])

    nrow(decomposition) == nrow(registry) || error("Case decomposition lost registry rows.")
    nrow(party_contributions) == sum(registry.coalition_party_count) || error("Incomplete party vectors.")
    nrow(party_district_contributions[party_district_contributions.case_domain .== "cabinet", :]) ==
        27 * sum(registry.coalition_party_count[registry.case_domain .== "cabinet"]) ||
        error("Cabinet member-cell output differs from current registry membership.")
    nrow(party_district_contributions) == 27 * nrow(party_contributions) || error("Incomplete party-district vectors.")
    nrow(district_contributions) == nrow(registry) * 27 || error("Incomplete coalition-district vectors.")
    return (
        decomposition = decomposition,
        party_contributions = party_contributions,
        district_contributions = district_contributions,
        party_district_contributions = party_district_contributions,
        validations = validations,
    )
end


function _ranking_metadata(row)
    return (
        case_id = String(row.case_id), source_case_id = String(row.source_case_id),
        case_domain = String(row.case_domain), case_order = Int(row.case_order),
        election_year = Int(row.election_year), case_label = String(row.case_label),
        cabinet_period = row.cabinet_period,
        source_periods = row.source_periods,
        period_start = row.period_start,
        period_end = row.period_end,
        period_days = row.period_days,
        ideology_start_index = row.ideology_start_index,
        ideology_end_index = row.ideology_end_index,
        minimal_inversion = row.minimal_inversion,
        minimal_status = String(row.minimal_status),
    )
end

function _append_ranking_rows!(rows, source::DataFrame, level::String, components)
    for row in eachrow(source)
        metadata = _ranking_metadata(row)
        party = level in ("party", "party_district") ? String(row.party) : missing
        electoral_unit = level in ("district", "party_district") ?
            String(row.electoral_unit) : missing
        unit_label = level == "party" ? String(party) :
            level == "district" ? String(electoral_unit) : "$(party)/$(electoral_unit)"
        for (component, column) in components
            value = Float64(row[column])
            push!(rows, merge(metadata, (
                aggregation_level = level, component = component, party = party,
                electoral_unit = electoral_unit, unit_label = unit_label, value = value,
                value_sign = value > 0 ? "positive" : value < 0 ? "negative" : "zero",
            )))
        end
    end
    return rows
end

"""
    build_case_rankings(cases)

Build complete deterministic rankings for party, district, and party--district
A/B/d contributions. Exact ties are broken by the displayed unit identifier.
"""
function build_case_rankings(cases)
    rows = NamedTuple[]
    _append_ranking_rows!(rows, cases.party_contributions, "party",
        (("A_i", :A_i), ("B_i", :B_i), ("d_i", :d_i)))
    _append_ranking_rows!(rows, cases.district_contributions, "district",
        (("a_Cd", :a_Cd), ("b_Cd", :b_Cd), ("d_Cd", :d_Cd)))
    _append_ranking_rows!(rows, cases.party_district_contributions, "party_district",
        (("a_id", :a_id), ("b_id", :b_id), ("d_id", :d_id)))
    rankings = DataFrame(rows)
    n = nrow(rankings)
    descending_rank = zeros(Int, n)
    ascending_rank = zeros(Int, n)
    absolute_rank = zeros(Int, n)
    positive_rank = Vector{Union{Missing,Int}}(missing, n)
    negative_rank = Vector{Union{Missing,Int}}(missing, n)

    for group in groupby(rankings, [:case_id, :aggregation_level, :component])
        indices = collect(parentindices(group)[1])
        descending = sort(indices; by = i -> (-rankings.value[i], rankings.unit_label[i]))
        ascending = sort(indices; by = i -> (rankings.value[i], rankings.unit_label[i]))
        absolute = sort(indices; by = i ->
            (-abs(rankings.value[i]), -rankings.value[i], rankings.unit_label[i]))
        for (rank, index) in enumerate(descending)
            descending_rank[index] = rank
        end
        for (rank, index) in enumerate(ascending)
            ascending_rank[index] = rank
        end
        for (rank, index) in enumerate(absolute)
            absolute_rank[index] = rank
        end
        for (rank, index) in enumerate(filter(i -> rankings.value[i] > 0, descending))
            positive_rank[index] = rank
        end
        for (rank, index) in enumerate(filter(i -> rankings.value[i] < 0, ascending))
            negative_rank[index] = rank
        end
    end
    rankings[!, :descending_rank] = descending_rank
    rankings[!, :ascending_rank] = ascending_rank
    rankings[!, :absolute_rank] = absolute_rank
    rankings[!, :positive_rank] = positive_rank
    rankings[!, :negative_rank] = negative_rank

    expected_rows = 3 * (nrow(cases.party_contributions) +
        nrow(cases.district_contributions) + nrow(cases.party_district_contributions))
    nrow(rankings) == expected_rows || error("Full contribution ranking row count changed.")
    all(rankings.descending_rank .> 0) || error("A descending rank was not assigned.")
    all(rankings.ascending_rank .> 0) || error("An ascending rank was not assigned.")
    all(rankings.absolute_rank .> 0) || error("An absolute rank was not assigned.")

    level_order = Dict("party" => 1, "district" => 2, "party_district" => 3)
    component_order = Dict("A_i" => 1, "B_i" => 2, "d_i" => 3,
        "a_Cd" => 1, "b_Cd" => 2, "d_Cd" => 3,
        "a_id" => 1, "b_id" => 2, "d_id" => 3)
    rankings[!, :_level_order] = [level_order[String(x)] for x in rankings.aggregation_level]
    rankings[!, :_component_order] = [component_order[String(x)] for x in rankings.component]
    sort!(rankings, [:case_domain, :election_year, :case_order, :_level_order,
        :_component_order, :descending_rank])
    select!(rankings, Not([:_level_order, :_component_order]))
    return rankings
end

function sha256_file(path::AbstractString)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end

function write_csv_file(path::AbstractString, data::DataFrame)
    mkpath(dirname(path))
    CSV.write(path, data; quotestrings = true)
    return path
end

function reload_csv(path::AbstractString)
    data = CSV.read(path, DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
    for column in (
        :case_id, :source_case_id, :case_domain, :case_label, :cabinet_period,
        :minimal_status, :party, :electoral_unit, :aggregation_level, :component,
        :unit_label, :value_sign, :coalition_parties,
    )
        column in propertynames(data) || continue
        data[!, column] = [ismissing(value) ? missing : string(value) for value in data[!, column]]
    end
    return data
end

function display_case(row)
    domain = String(row.case_domain) == "cabinet" ? "Cabinet" : "Ideological"
    return "$(domain) $(row.election_year)/$(row.case_label)"
end

function build_year_closure_table(cells::DataFrame, parties::DataFrame, districts::DataFrame)
    rows = NamedTuple[]
    for year in sort(unique(Int.(cells.election_year)))
        cell = cells[Int.(cells.election_year) .== year, :]
        party = parties[Int.(parties.election_year) .== year, :]
        district = districts[Int.(districts.election_year) .== year, :]
        push!(rows, (
            election_year = year,
            parties = nrow(party),
            electoral_units = nrow(district),
            party_district_cells = nrow(cell),
            V = only(unique(Int.(cell.V))),
            S = only(unique(Int.(cell.S))),
            sum_A_i = sum(Float64.(party.A_i)),
            sum_B_i = sum(Float64.(party.B_i)),
            sum_d_i = sum(Float64.(party.d_i)),
            max_abs_b_crosscheck_residual = maximum(abs.(Float64.(cell.b_crosscheck_residual))),
            max_abs_district_b_closure_residual = maximum(abs.(Float64.(district.b_closure_residual))),
            status = "PASS",
        ))
    end
    return DataFrame(rows)
end

function build_district_weight_extremes_table(districts::DataFrame; count::Int = 3)
    rows = NamedTuple[]
    for year in sort(unique(Int.(districts.election_year)))
        selected = districts[Int.(districts.election_year) .== year, :]
        high = sort(selected, [:district_weight_gap, :electoral_unit]; rev = [true, false])
        low = sort(selected, [:district_weight_gap, :electoral_unit]; rev = [false, false])
        for (direction, data) in (("largest positive", high), ("most negative", low))
            for rank in 1:min(count, nrow(data))
                row = data[rank, :]
                push!(rows, (
                    election_year = year, direction = direction, rank = rank,
                    electoral_unit = String(row.electoral_unit), V_d = Int(row.V_d),
                    S_d = Int(row.S_d), district_vote_weight = Float64(row.district_vote_weight),
                    district_seat_weight = Float64(row.district_seat_weight),
                    district_weight_gap = Float64(row.district_weight_gap),
                    seat_equivalent_weight_gap = Float64(row.seat_equivalent_weight_gap),
                ))
            end
        end
    end
    return DataFrame(rows)
end

function build_registry_table(registry::DataFrame)
    rows = NamedTuple[]
    for row in eachrow(registry)
        push!(rows, (
            case_id = String(row.case_id), case_domain = String(row.case_domain),
            election_year = Int(row.election_year), case_order = Int(row.case_order),
            case_label = String(row.case_label), case_display = display_case(row),
            coalition_party_count = Int(row.coalition_party_count),
            coalition_parties = String(row.coalition_parties),
            minimal_status = String(row.minimal_status), vote_share = Float64(row.vote_share),
            s_C = Int(row.s_C), compositionally_repeated = Bool(row.compositionally_repeated),
            source_registry = String(row.source_registry),
        ))
    end
    return DataFrame(rows)
end

function build_decomposition_table(decomposition::DataFrame)
    rows = NamedTuple[]
    for row in eachrow(decomposition)
        push!(rows, (
            case_id = String(row.case_id), case_domain = String(row.case_domain),
            election_year = Int(row.election_year), case_order = Int(row.case_order),
            case_label = String(row.case_label), case_display = display_case(row),
            minimal_status = String(row.minimal_status), vote_share = Float64(row.vote_share),
            s_C = Int(row.s_C), q_C = Float64(row.q_C), d_C = Float64(row.d_C),
            r_C = Float64(row.r_C), R_C = Float64(row.R_C), A_C = Float64(row.A_C),
            B_C = Float64(row.B_C), A_share_of_d_C = Float64(row.A_share_of_d_C),
            B_share_of_d_C = Float64(row.B_share_of_d_C),
            dominant_absolute_component = String(row.dominant_absolute_component),
            component_sign_pattern = String(row.component_sign_pattern),
        ))
    end
    return DataFrame(rows)
end

function rank_extreme(rankings::DataFrame, case_id, level, component, rank_column)
    mask = (String.(rankings.case_id) .== String(case_id)) .&
        (String.(rankings.aggregation_level) .== String(level)) .&
        (String.(rankings.component) .== String(component))
    candidates = rankings[mask, :]
    values = candidates[!, rank_column]
    selected = candidates[coalesce.(values .== 1, false), :]
    nrow(selected) <= 1 || error(
        "$(case_id)/$(level)/$(component): rank $(rank_column)=1 is not unique.",
    )
    return nrow(selected) == 0 ? nothing : selected[1, :]
end

function build_component_extremes_table(decomposition::DataFrame, rankings::DataFrame)
    rows = NamedTuple[]
    specs = (
        ("party", "A_i"), ("party", "B_i"), ("party", "d_i"),
        ("district", "a_Cd"), ("district", "b_Cd"), ("district", "d_Cd"),
    )
    for case in eachrow(decomposition)
        for (level, component) in specs
            positive = rank_extreme(rankings, case.case_id, level, component, :positive_rank)
            negative = rank_extreme(rankings, case.case_id, level, component, :negative_rank)
            push!(rows, (
                case_id = String(case.case_id), case_domain = String(case.case_domain),
                election_year = Int(case.election_year), case_order = Int(case.case_order),
                case_label = String(case.case_label), case_display = display_case(case),
                aggregation_level = level, component = component,
                largest_positive_unit = positive === nothing ? missing : String(positive.unit_label),
                largest_positive_value = positive === nothing ? missing : Float64(positive.value),
                largest_negative_unit = negative === nothing ? missing : String(negative.unit_label),
                largest_negative_value = negative === nothing ? missing : Float64(negative.value),
            ))
        end
    end
    return DataFrame(rows)
end

function build_party_vectors_table(parties::DataFrame)
    rows = NamedTuple[]
    for row in eachrow(parties)
        push!(rows, (
            case_id = String(row.case_id), case_domain = String(row.case_domain),
            election_year = Int(row.election_year), case_order = Int(row.case_order),
            case_label = String(row.case_label), case_display = display_case(row),
            coalition_party_order = Int(row.coalition_party_order), party = String(row.party),
            v_i = Int(row.v_i), s_i = Int(row.s_i), q_i = Float64(row.q_i),
            R_i = ismissing(row.R_i) ? missing : Float64(row.R_i), d_i = Float64(row.d_i),
            A_i = Float64(row.A_i), B_i = Float64(row.B_i),
            accounting_qualification = String(row.accounting_qualification),
        ))
    end
    return DataFrame(rows)
end

function build_district_vectors_table(districts::DataFrame)
    rows = NamedTuple[]
    for row in eachrow(districts)
        push!(rows, (
            case_id = String(row.case_id), case_domain = String(row.case_domain),
            election_year = Int(row.election_year), case_order = Int(row.case_order),
            case_label = String(row.case_label), case_display = display_case(row),
            electoral_unit = String(row.electoral_unit), v_Cd = Int(row.v_Cd),
            V_d = Int(row.V_d), s_Cd = Int(row.s_Cd), S_d = Int(row.S_d),
            a_Cd = Float64(row.a_Cd), b_Cd = Float64(row.b_Cd), d_Cd = Float64(row.d_Cd),
        ))
    end
    return DataFrame(rows)
end

function build_cell_extremes_table(decomposition::DataFrame, rankings::DataFrame)
    rows = NamedTuple[]
    for case in eachrow(decomposition), component in ("a_id", "b_id", "d_id")
        positive = rank_extreme(rankings, case.case_id, "party_district", component, :positive_rank)
        negative = rank_extreme(rankings, case.case_id, "party_district", component, :negative_rank)
        push!(rows, (
            case_id = String(case.case_id), case_domain = String(case.case_domain),
            election_year = Int(case.election_year), case_order = Int(case.case_order),
            case_label = String(case.case_label), case_display = display_case(case),
            component = component,
            largest_positive_party = positive === nothing ? missing : String(positive.party),
            largest_positive_electoral_unit = positive === nothing ? missing : String(positive.electoral_unit),
            largest_positive_value = positive === nothing ? missing : Float64(positive.value),
            largest_negative_party = negative === nothing ? missing : String(negative.party),
            largest_negative_electoral_unit = negative === nothing ? missing : String(negative.electoral_unit),
            largest_negative_value = negative === nothing ? missing : Float64(negative.value),
        ))
    end
    return DataFrame(rows)
end

function build_interpretation_source(decomposition::DataFrame, rankings::DataFrame)
    rows = NamedTuple[]
    for case in eachrow(decomposition)
        party_positive = rank_extreme(rankings, case.case_id, "party", "d_i", :positive_rank)
        party_negative = rank_extreme(rankings, case.case_id, "party", "d_i", :negative_rank)
        district_A = rank_extreme(rankings, case.case_id, "district", "a_Cd", :absolute_rank)
        district_B = rank_extreme(rankings, case.case_id, "district", "b_Cd", :absolute_rank)
        cell_A = rank_extreme(rankings, case.case_id, "party_district", "a_id", :absolute_rank)
        cell_B = rank_extreme(rankings, case.case_id, "party_district", "b_id", :absolute_rank)
        push!(rows, (
            case_id = String(case.case_id), case_domain = String(case.case_domain),
            election_year = Int(case.election_year), case_order = Int(case.case_order),
            case_label = String(case.case_label), case_display = display_case(case),
            minimal_status = String(case.minimal_status), d_C = Float64(case.d_C),
            A_C = Float64(case.A_C), B_C = Float64(case.B_C),
            component_sign_pattern = String(case.component_sign_pattern),
            largest_positive_party_d = party_positive === nothing ? missing : String(party_positive.unit_label),
            largest_positive_party_d_value = party_positive === nothing ? missing : Float64(party_positive.value),
            largest_negative_party_d = party_negative === nothing ? missing : String(party_negative.unit_label),
            largest_negative_party_d_value = party_negative === nothing ? missing : Float64(party_negative.value),
            largest_absolute_A_district = district_A === nothing ? missing : String(district_A.unit_label),
            largest_absolute_A_district_value = district_A === nothing ? missing : Float64(district_A.value),
            largest_absolute_B_district = district_B === nothing ? missing : String(district_B.unit_label),
            largest_absolute_B_district_value = district_B === nothing ? missing : Float64(district_B.value),
            largest_absolute_a_cell = cell_A === nothing ? missing : String(cell_A.unit_label),
            largest_absolute_a_cell_value = cell_A === nothing ? missing : Float64(cell_A.value),
            largest_absolute_b_cell = cell_B === nothing ? missing : String(cell_B.unit_label),
            largest_absolute_b_cell_value = cell_B === nothing ? missing : Float64(cell_B.value),
        ))
    end
    return DataFrame(rows)
end

tex(value) = ismissing(value) ? "--" : CD.latex_escape(value)
texint(value) = ismissing(value) ? "--" : string(Int(value))
texnum(value) = ismissing(value) ? "--" : fmt3(value)
texnum2(value) = ismissing(value) ? "--" : fmt2(value)
texshare(value) = ismissing(value) ? "--" : fmtpct(value)

"""Write complete case/member/district evidence and compact CSV summaries."""
function write_accounting_evidence_outputs(
    output_root::AbstractString,
    full,
    registry::DataFrame,
    cases,
    rankings::DataFrame;
    party_size_diagnostics,
    party_size_artifacts = write_party_size_diagnostic_outputs(output_root, full, party_size_diagnostics),
)
    raw_dir = joinpath(output_root, "raw")
    table_dir = joinpath(output_root, "tables", "summaries")
    audit_dir = joinpath(output_root, "audit")
    foreach(mkpath, (raw_dir, table_dir, audit_dir))

    artifacts = NamedTuple[]
    function record_csv(relative_path, data, artifact_type, description)
        path = joinpath(output_root, relative_path)
        write_csv_file(path, data)
        push!(artifacts, (
            path = relative_path, artifact_type = artifact_type,
            description = description, rows = nrow(data), columns = length(names(data)),
            bytes = filesize(path), sha256 = sha256_file(path),
        ))
        return path
    end
    # Exact panels and party-size summaries have one writer. This report is a
    # view of those saved objects, not another scientific output route.
    source_paths = Dict{Symbol,String}(
        :cells => joinpath(output_root, "raw/party_district_accounting_all_years.csv"),
        :parties => joinpath(output_root, "raw/party_accounting_all_years.csv"),
        :districts => joinpath(output_root, "raw/district_accounting_all_years.csv"),
    )
    for artifact in party_size_artifacts
        push!(artifacts, (
            path = artifact.path, artifact_type = artifact.artifact_type,
            description = artifact.description, rows = artifact.rows, columns = artifact.columns,
            bytes = filesize(joinpath(output_root, artifact.path)), sha256 = artifact.sha256,
        ))
    end
    source_paths[:registry] = record_csv(
        "raw/inversion_case_registry.csv", registry, "raw",
        "Combined cabinet and ideological inversion registry.")
    source_paths[:decomposition] = record_csv(
        "raw/all_inversion_decomposition.csv", cases.decomposition, "raw",
        "Combined registry-derived exact-audited coalition decomposition.")
    source_paths[:case_parties] = record_csv(
        "raw/all_inversion_party_contributions.csv", cases.party_contributions, "raw",
        "Combined full member-party accounting vectors for all inversion cases.")
    source_paths[:case_districts] = record_csv(
        "raw/all_inversion_district_contributions.csv", cases.district_contributions, "raw",
        "Combined district accounting vectors for all inversion cases.")
    source_paths[:case_cells] = record_csv(
        "raw/all_inversion_party_district_contributions.csv",
        cases.party_district_contributions, "raw",
        "Combined case-linked member-party-by-district accounting cells.")
    source_paths[:rankings] = record_csv(
        "raw/all_inversion_contribution_rankings.csv", rankings, "raw",
        "Complete deterministic party, district, and cell rankings for A/B/d components.")

    for domain in ("cabinet", "ideological")
        decomposition = cases.decomposition[cases.decomposition.case_domain .== domain, :]
        parties = cases.party_contributions[cases.party_contributions.case_domain .== domain, :]
        districts = cases.district_contributions[cases.district_contributions.case_domain .== domain, :]
        cells = cases.party_district_contributions[
            cases.party_district_contributions.case_domain .== domain, :,
        ]
        record_csv("raw/$(domain)_inversion_decomposition.csv", decomposition, "raw",
            "$(uppercasefirst(domain))-only coalition decomposition.")
        record_csv("raw/$(domain)_inversion_party_contributions.csv", parties, "raw",
            "$(uppercasefirst(domain))-only member-party accounting vectors.")
        record_csv("raw/$(domain)_inversion_district_contributions.csv", districts, "raw",
            "$(uppercasefirst(domain))-only district accounting vectors.")
        record_csv("raw/$(domain)_inversion_party_district_contributions.csv", cells, "raw",
            "$(uppercasefirst(domain))-only linked member-party-by-district cells.")
    end

    validations = vcat(full.validations, cases.validations; cols = :union)
    nrow(validations) == nrow(full.validations) + nrow(cases.validations) || error("Identity audit cardinality mismatch.")
    source_paths[:validations] = record_csv(
        "audit/accounting_evidence_identity_checks.csv", validations, "audit",
        "Exact complete-system and registry-derived accounting identity checks.")
    # From this point onward, all empirical table rows come from reloaded CSVs.
    cells = reload_csv(source_paths[:cells])
    parties = reload_csv(source_paths[:parties])
    districts = reload_csv(source_paths[:districts])
    registry_disk = reload_csv(source_paths[:registry])
    decomposition = reload_csv(source_paths[:decomposition])
    case_parties = reload_csv(source_paths[:case_parties])
    case_districts = reload_csv(source_paths[:case_districts])
    ranking_disk = reload_csv(source_paths[:rankings])

    nrow(cells) == EXPECTED_PARTY_DISTRICT_ROWS || error("Reloaded full cell panel changed.")
    nrow(case_parties) == sum(registry_disk.coalition_party_count) || error("Reloaded case-party output lost registry members.")
    nrow(case_districts) == 27 * nrow(registry_disk) || error("Reloaded case-district output lost registered districts.")
    nrow(ranking_disk) == nrow(rankings) || error("Reloaded ranking source cardinality changed.")

    table_paths = Dict{Symbol,String}()
    table_data = Dict{Symbol,DataFrame}()
    table_data[:interpretation] = build_interpretation_source(decomposition, ranking_disk)
    table_data[:closure] = build_year_closure_table(cells, parties, districts)
    table_data[:district_weights] = build_district_weight_extremes_table(districts)
    table_data[:registry] = build_registry_table(registry_disk)
    table_data[:decomposition] = build_decomposition_table(decomposition)
    table_data[:component_extremes] = build_component_extremes_table(decomposition, ranking_disk)
    table_data[:party_vectors] = build_party_vectors_table(case_parties)
    table_data[:district_vectors] = build_district_vectors_table(case_districts)
    table_data[:cell_extremes] = build_cell_extremes_table(decomposition, ranking_disk)
    for year in (2014, 2018, 2022)
        table_data[Symbol("cells_$(year)")] = cells[Int.(cells.election_year) .== year, :]
    end

    table_specs = (
        (:interpretation, "generated_interpretation_source.csv",
            "Case-level source for procedurally generated substantive interpretation."),
        (:closure, "table_year_accounting_closure.csv",
            "Election-year complete-panel and closure summary."),
        (:district_weights, "table_district_weight_extremes.csv",
            "Largest positive and negative district seat/valid-vote weight gaps."),
        (:registry, "table_inversion_case_registry.csv",
            "Compact cabinet and ideological inversion registry."),
        (:decomposition, "table_all_inversion_decomposition.csv",
            "Registry-derived coalition accounting decomposition table."),
        (:component_extremes, "table_case_component_extremes.csv",
            "Party and district positive/negative component extremes."),
        (:party_vectors, "table_case_party_vectors.csv",
            "Complete member-party vectors for all inversion cases."),
        (:district_vectors, "table_case_district_vectors.csv",
            "Complete district vectors for all inversion cases."),
        (:cell_extremes, "table_case_party_district_extremes.csv",
            "Party-by-district positive/negative cell extremes."),
        (:cells_2014, "table_party_district_accounting_2014.csv",
            "Complete 2014 party-by-district accounting panel."),
        (:cells_2018, "table_party_district_accounting_2018.csv",
            "Complete 2018 party-by-district accounting panel."),
        (:cells_2022, "table_party_district_accounting_2022.csv",
            "Complete 2022 party-by-district accounting panel."),
    )
    for (key, filename, description) in table_specs
        table_paths[key] = record_csv(
            joinpath("tables", "summaries", filename), table_data[key], "table", description,
        )
    end

    generation_checks = DataFrame([
        (check_name = "full party-district rows", observed = nrow(cells),
            expected = EXPECTED_PARTY_DISTRICT_ROWS, status = "PASS"),
        (check_name = "all inversion cases", observed = nrow(decomposition),
            expected = nrow(registry), status = "PASS"),
        (check_name = "all case-party rows", observed = nrow(case_parties),
            expected = sum(registry.coalition_party_count), status = "PASS"),
        (check_name = "all case-district rows", observed = nrow(case_districts),
            expected = 27 * nrow(registry), status = "PASS"),
        (check_name = "all case party-district rows",
            observed = nrow(reload_csv(source_paths[:case_cells])),
            expected = 27 * sum(registry.coalition_party_count), status = "PASS"),
        (check_name = "full ranking rows", observed = nrow(ranking_disk),
            expected = nrow(rankings), status = "PASS"),
        (check_name = "exact identity checks", observed = nrow(validations),
            expected = nrow(full.validations) + nrow(cases.validations), status = "PASS"),
    ])
    all(generation_checks.observed .== generation_checks.expected) || error(
        "One or more intermediate-accounting generation cardinalities failed.",
    )
    record_csv(
        "audit/accounting_evidence_generation_checks.csv", generation_checks, "audit",
        "Report-output cardinality and generation-boundary checks.")

    manifest = DataFrame(artifacts)
    sort!(manifest, :path)
    all(startswith.(String.(manifest.path), Ref("raw/")) .|
        startswith.(String.(manifest.path), Ref("tables/summaries/")) .|
        startswith.(String.(manifest.path), Ref("audit/"))) || error(
            "Intermediate report manifest contains a path outside the isolated output tree.",
        )
    manifest_path = joinpath(audit_dir, "accounting_evidence_artifacts.csv")
    CSV.write(manifest_path, manifest; quotestrings = true)
    return manifest
end

include(joinpath(@__DIR__, "PartySizeDiagnostics.jl"))

end # module AccountingEvidence
