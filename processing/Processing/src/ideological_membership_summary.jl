"""Validate actual membership in the domain-minimal winning coalition registry."""
function validate_k_gap_membership_registry!(registry)
    required = (:election, :ideological_universe, :k, :coalition_id, :parties, :party_count, :gap_count,
                :omitted_party, :minimal_seat_majority, :seat_majority, :inversion,
                :votes, :national_vote_total, :seats, :seat_majority_threshold)
    all(column -> column in propertynames(registry), required) || error(
        "K-gap membership registry is missing required columns.")
    seen = Set{Tuple{Int,String,Int,String}}()
    for row in eachrow(registry)
        row.election isa Integer && !(row.election isa Bool) || error("Invalid election year.")
        row.k isa Integer && !(row.k isa Bool) && row.k in (0, 1) || error("Invalid k-gap domain.")
        row.ideological_universe in ("seat_winning", "all_parties") || error("Invalid ideological universe.")
        key = (Int(row.election), String(row.ideological_universe), Int(row.k), String(row.coalition_id))
        key in seen && error("Duplicate minimal coalition: $(key).")
        push!(seen, key)
        row.minimal_seat_majority === true && row.seat_majority === true || error(
            "Membership registry contains a non-minimal or non-winning coalition: $(key).")
        row.seats >= row.seat_majority_threshold || error("Invalid winning status: $(key).")
        row.inversion isa Bool && row.inversion == (2 * row.votes < row.national_vote_total) || error(
            "Invalid inversion status: $(key).")
        row.party_count isa Integer && !(row.party_count isa Bool) && row.party_count > 0 || error(
            "Coalition member counts must be positive integers: $(key).")
        # coalition_id is the canonical ordered member list in the stated universe.
        # Never substitute an endpoint distance or ideological span for this count.
        members = split(row.coalition_id, '|'; keepempty = true)
        all(member -> !isempty(strip(member)), members) && allunique(members) || error(
            "Invalid canonical coalition membership: $(key).")
        members == strip.(split(row.parties, ','; keepempty = true)) || error(
            "Canonical ID and party list disagree: $(key).")
        row.party_count == length(members) || error("Member count disagrees with canonical ID: $(key).")
        omitted = ismissing(row.omitted_party) ? "" : String(row.omitted_party)
        row.gap_count isa Integer && 0 <= row.gap_count <= row.k || error("Invalid gap count: $(key).")
        row.gap_count == Int(!isempty(omitted)) || error("Omission and gap count disagree: $(key).")
        omitted in members && error("Omitted interior party counted as a member: $(key).")
    end
    return true
end

function coalition_membership_statistics(counts)
    isempty(counts) && return (median = missing, min = missing, max = missing)
    return (median = median(counts), min = minimum(counts), max = maximum(counts))
end

"""Summarize domain-minimal winning coalitions, using verified canonical party_count."""
function build_k_gap_membership_summary(registry)
    validate_k_gap_membership_registry!(registry)
    rows = NamedTuple[]
    for domain in groupby(registry, [:election, :ideological_universe, :k]; sort = true)
        inverted = domain.party_count[domain.inversion]
        non_inverted = domain.party_count[.!domain.inversion]
        inv = coalition_membership_statistics(inverted)
        non = coalition_membership_statistics(non_inverted)
        push!(rows, (
            election = Int(first(domain.election)),
            ideological_universe = String(first(domain.ideological_universe)),
            k = Int(first(domain.k)),
            minimal_seat_majority_coalitions = nrow(domain),
            minimal_inversions = length(inverted),
            non_inverted_minimal_majorities = length(non_inverted),
            inverted_members_median = inv.median, inverted_members_min = inv.min,
            inverted_members_max = inv.max,
            non_inverted_members_median = non.median, non_inverted_members_min = non.min,
            non_inverted_members_max = non.max,
        ))
    end
    return DataFrame(rows)
end

"""Reconcile every count and inversion-specific statistic with the source registry."""
function validate_k_gap_membership_summary!(summary, registry)
    expected = build_k_gap_membership_summary(registry)
    all(column -> column in propertynames(summary), propertynames(expected)) || error(
        "K-gap summary is missing membership columns.")
    nrow(summary) == nrow(expected) || error("K-gap membership summary row count changed.")
    for (row, source) in zip(eachrow(summary), eachrow(expected))
        for column in propertynames(expected)
            isequal(row[column], source[column]) || error(
                "K-gap membership summary disagrees with registry at $(source.election)/k=$(source.k), $(column): $(row[column]) != $(source[column]).")
        end
        row.minimal_inversions + row.non_inverted_minimal_majorities == row.minimal_seat_majority_coalitions || error(
            "Inverted and non-inverted counts do not sum to minimal majorities.")
    end
    return true
end

"""Keep the established all-party regression gate separate from the new primary domain.

Both sets of expectations are checked against the recomputed registry and
admissible-domain minimality audits; neither supplies rendering data.
"""
function validate_k_gap_membership_regression!(summary)
    :ideological_universe in propertynames(summary) || error("Summary must identify its ideological universe.")
    expected_keys = [(year, k) for year in (2014, 2018, 2022) for k in (0, 1)]
    expected_all_parties = [
        (8, 4, (15, 12, 16), (12, 12, 14)),
        (88, 43, (14, 11, 19), (14, 11, 19)),
        (8, 0, (missing, missing, missing), (16.5, 15, 20)),
        (118, 24, (17, 14, 19), (17, 14, 21)),
        (4, 2, (11.5, 8, 15), (20, 19, 21)),
        (53, 17, (14, 7, 16), (19, 14, 21)),
    ]
    # Parliamentary expectations were audited after independent re-enumeration,
    # using the unchanged national vote denominator (not filtered prior results).
    expected_seat_winning = [
        (8, 4, (14, 12, 15), (12, 12, 13)),
        (87, 46, (13, 11, 18), (13, 11, 18)),
        (8, 1, (14, 14, 14), (15, 14, 18)),
        (108, 42, (17, 13, 18), (15, 13, 19)),
        (4, 2, (8.5, 7, 10), (15.5, 15, 16)),
        (39, 12, (9, 7, 11), (14, 10, 16)),
    ]
    isempty(summary) && error("K-gap membership summary is empty.")
    for domain in groupby(summary, :ideological_universe; sort = true)
        universe = String(first(domain.ideological_universe))
        universe in ("seat_winning", "all_parties") || error("Invalid ideological universe $(universe).")
        collect(zip(domain.election, domain.k)) == expected_keys || error(
            "Each universe must contain six rows ordered by election (2014, 2018, 2022), then k (0, 1).")
        for (index, row) in enumerate(eachrow(domain))
            row.minimal_seat_majority_coalitions >= row.minimal_inversions >= 0 || error("Invalid minimal coalition counts.")
            row.non_inverted_minimal_majorities + row.minimal_inversions == row.minimal_seat_majority_coalitions || error(
                "Inverted and non-inverted counts do not sum to minimal majorities.")
            expected = universe == "all_parties" ? expected_all_parties : expected_seat_winning
            actual = (row.minimal_seat_majority_coalitions, row.minimal_inversions,
                (row.inverted_members_median, row.inverted_members_min, row.inverted_members_max),
                (row.non_inverted_members_median, row.non_inverted_members_min, row.non_inverted_members_max))
            isequal(actual, expected[index]) || error(
                "$(universe) membership regression failed at $(row.election)/k=$(row.k): computed $(actual), expected $(expected[index]).")
        end
    end
    return true
end

function coalition_membership_cell(med, low, high)
    all(ismissing, (med, low, high)) && return "None"
    any(ismissing, (med, low, high)) && error("Incomplete membership statistics.")
    low > 0 && isinteger(low) && isinteger(high) && low <= med <= high && isinteger(2 * med) || error(
        "Invalid membership median or range.")
    median_text = isinteger(med) ? string(Int(med)) : string(Float64(med))
    return "$(median_text) [$(Int(low))--$(Int(high))]"
end

"""Render the main exact-connected baseline from the validated CSV summary."""
