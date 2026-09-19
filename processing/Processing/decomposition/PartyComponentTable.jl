"""
    party_component_extremes(contributions, focal_summary)

Audit and rank the existing serialized case-party A_i/B_i vectors. Reuse the
same focal registry as the d_i appendix; no electoral accounting is recomputed.
Rank by exact signed values (most negative first), breaking ties by party label.
"""
function party_component_extremes(contributions::DataFrame, focal_summary::DataFrame)
    table = select(sort(focal_summary, :focal_order),
        :case_identifier, :case, :domain, :election, :ideological_universe,
        :k, :cabinet_period, :coalition_start_party, :coalition_end_party, :focal_order)
    for component in (:A, :B), sign in (:positive, :negative), rank in 1:2
        prefix = "$(component)_$(sign)_$(rank)"
        table[!, Symbol(prefix * "_party")] = Union{Missing,String}[missing for _ in 1:nrow(table)]
        table[!, Symbol(prefix * "_value")] = Union{Missing,Float64}[missing for _ in 1:nrow(table)]
        table[!, Symbol(prefix * "_exact")] = Union{Missing,String}[missing for _ in 1:nrow(table)]
    end
    checks = NamedTuple[]
    for (index, case) in enumerate(eachrow(sort(focal_summary, :focal_order)))
        members = contributions[contributions.case_identifier .== case.case_identifier, :]
        require(nrow(members) == case.coalition_party_count,
            "$(case.case_identifier): component table member count mismatch.")
        require(Set(String.(members.party)) == Set(ordered_parties(case.coalition_parties)),
            "$(case.case_identifier): component table membership mismatch.")
        A = parse_exact.(members.A_i_exact)
        B = parse_exact.(members.B_i_exact)
        d = parse_exact.(members.party_differential_d_i_exact)
        A_C, B_C = parse_exact(members.A_C_exact[1]), parse_exact(members.B_C_exact[1])
        party_pass = all(d .== A .+ B)
        A_pass = all(parse_exact.(members.A_C_exact) .== sum(A))
        B_pass = all(parse_exact.(members.B_C_exact) .== sum(B))
        coalition_pass = parse_exact(case.d_C_exact) == A_C + B_C
        residual = maximum(abs, members.party_differential_d_i .- members.A_i .- members.B_i)
        A_residual = abs(sum(members.A_i) - members.A_C[1])
        B_residual = abs(sum(members.B_i) - members.B_C[1])
        coalition_residual = abs(case.d_C - members.A_C[1] - members.B_C[1])
        floating_pass = maximum((residual, A_residual, B_residual, coalition_residual)) <= 1e-10
        require(party_pass && A_pass && B_pass && coalition_pass && floating_pass,
            "$(case.case_identifier): member-party component identities failed.")
        push!(checks, (case_identifier = String(case.case_identifier),
            party_count = nrow(members), party_identity_pass = party_pass,
            A_sum_pass = A_pass, B_sum_pass = B_pass, coalition_identity_pass = coalition_pass,
            max_party_residual = residual, A_sum_residual = A_residual,
            B_sum_residual = B_residual, coalition_residual = coalition_residual,
            floating_pass = floating_pass))
        for (component, values) in ((:A, A), (:B, B)), sign in (:positive, :negative)
            indices = [i for i in eachindex(values) if sign == :positive ? values[i] > 0 : values[i] < 0]
            sort!(indices; by = i -> (sign == :positive ? -values[i] : values[i], String(members.party[i])))
            for rank in 1:2
                entry = ranked_contributor(members, values, indices, rank)
                prefix = "$(component)_$(sign)_$(rank)"
                table[index, Symbol(prefix * "_party")] = entry.party
                table[index, Symbol(prefix * "_value")] = entry.value
                table[index, Symbol(prefix * "_exact")] = entry.value_exact
            end
        end
    end
    return table, DataFrame(checks)
end

