# Table-specific aggregation of existing exact district contributions. Scalar prose
# cites this table's machine-readable output and its raw concentration summaries.
function cabinet_district_concentration(states::DataFrame)
    records = NamedTuple[]
    cabinets = states[states.case_domain .== "cabinet", :]
    for rows in groupby(cabinets, :case_id)
        first_row = first(eachrow(rows))
        contributions = parse_exact.(rows.a_Cd_exact)
        positive = sort(filter(>(0), contributions); rev = true)
        negative = filter(<(0), contributions)
        positive_sum = sum(positive; init = 0//1)
        top_three_share = iszero(positive_sum) ? missing : sum(first(positive, min(3, length(positive)))) / positive_sum
        ninety_count = iszero(positive_sum) ? missing : findfirst(>=(9//10 * positive_sum), cumsum(positive))
        push!(records, (case_id = first_row.case_id, election_year = first_row.election_year,
            cabinet_period = first_row.cabinet_period, case_domain = "cabinet",
            ideological_universe = "not_applicable", positive_count = length(positive),
            negative_count = length(negative), positive_sum = Float64(positive_sum),
            negative_sum = Float64(sum(negative)), top_three_positive_share = ismissing(top_three_share) ? missing : Float64(top_three_share),
            districts_for_ninety_pct = ninety_count,
            positive_sum_exact = exact_text(positive_sum), negative_sum_exact = exact_text(sum(negative)),
            top_three_positive_share_exact = ismissing(top_three_share) ? missing : exact_text(top_three_share)))
    end
    isempty(records) ? DataFrame([name => Any[] for name in
        ["case_id", "election_year", "cabinet_period", "case_domain", "ideological_universe",
         "positive_count", "negative_count", "positive_sum", "negative_sum",
         "top_three_positive_share", "districts_for_ninety_pct", "positive_sum_exact",
         "negative_sum_exact", "top_three_positive_share_exact"]]) : DataFrame(records)
end

