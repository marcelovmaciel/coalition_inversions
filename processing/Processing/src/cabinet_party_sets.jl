# Shared views of the Python chronology registry. No local deduplication rule.
const CABINET_SET_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "build", "results", "cabinet_sets"))
function cabinet_set_identity()
    CabinetRelease.calendar_table() # Validate the public input even in standalone decomposition.
    CSV.read(joinpath(CABINET_SET_ROOT, "identity.csv"), DataFrame; stringtype=String)
end

"""Verify every linked electoral vector and keep one per registered membership.

The legacy period/cabinet_period columns in this internal adapter carry the
short display label only. Explicit IDs and occurrence references accompany it.
period_start/end are extrema, never an uninterrupted duration; period_days is
the union of actual dates, supplied by the authoritative daily registry.
"""
function cabinet_set_view(periods::DataFrame)
    identity = cabinet_set_identity()
    is_accounting = :coalition_id in propertynames(periods)
    label_col = is_accounting ? :cabinet_period : :period
    members_col = is_accounting ? :coalition_parties : :parties
    vector_cols = intersect(propertynames(periods), [:votes,:national_vote_total,:seats,:vote_share,:seat_share,
        :quota,:seat_diff,:required_diff,:representation_ratio,:vote_majority,:seat_majority,:majority_status,
        :coalition_inversion,:v_C,:V,:s_C,:S,:q_C,:d_C,:r_C,:R_C,:A_C,:B_C])
    rows = NamedTuple[]; consumed = String[]
    for reg in eachrow(identity)
        labels = Set(split(reg.analytical_period_labels, ';'))
        linked = periods[(periods.election_year .== reg.election_year) .& in.(String.(periods[!,label_col]),Ref(labels)), :]
        sort!(linked, :period_start)
        nrow(linked) == reg.analytical_period_count || error("Set registry missing occurrence: $(reg.display_label)")
        for p in eachrow(linked)
            join(sort(unique(strip.(split(String(p[members_col]), ',')))), ";") == reg.canonical_membership || error("Set membership mismatch")
            for col in vector_cols
                isequal(p[col],linked[1,col]) || error("Recurrent set electoral vector differs: $(reg.display_label)/$col")
            end
        end
        sum(linked.days_overlapping_mandate) == reg.total_observed_days || error("Set duration does not reconcile")
        append!(consumed,String.(linked[!,label_col]))
        firstrow = NamedTuple(linked[1,:])
        overrides = (source_periods=JSON3.write(split(reg.analytical_period_ids,';')),
            period_start=Date(reg.first_observed),period_end=Date(reg.last_observed),
            period_days=Int(reg.total_observed_days),days_overlapping_mandate=Int(reg.total_observed_days))
        overrides = merge(overrides, NamedTuple{(label_col,)}((reg.display_label,)))
        if is_accounting
            overrides = merge(overrides,(coalition_id=reg.cabinet_party_set_id,))
        else
            overrides = merge(overrides,(share_of_mandate=reg.total_observed_days/(reg.election_year==2022 ? 1174 : 1461),
                administration_id=reg.administrations,composition_status=reg.evidence_status))
        end
        push!(rows,merge(firstrow,NamedTuple(reg),overrides))
    end
    length(consumed)==nrow(periods) && allunique(consumed) || error("Cabinet periods not linked exactly once")
    DataFrame(rows)
end
