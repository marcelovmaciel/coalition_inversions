module ProseSummaries

# Raw summaries of ALREADY COMPUTED CSV outputs, without display rules, scalar
# TeX definitions, or prose injection. Direct observations stay in their original
# CSVs; this module adds only aggregations and the existing q_C + A_C intermediate.
using CSV, DataFrames, SHA, Statistics
export SUMMARY_SPECS, load_summary_sources, build_summaries, write_prose_summaries,
       audit_component_dominance, refresh_prose_summaries

const DOMINANCE_SUMMARY = "ideology-component-dominance"
const DOMINANCE_METRICS = (:A_C_gt_B_C, :A_C_lt_B_C, :A_C_eq_B_C)
# Match cross_domain_components.py's export tolerance. Dominance/ties instead
# use strict comparisons on the unrounded stored values, with no tolerance.
const DOMINANCE_ATOL = 1e-10
const SUMMARY_KEY = [:summary, :metric, :aggregation, :ideological_universe, :k, :election]

const SOURCE_FILES = Dict(
    "cabinet" => (:accounting, "raw/accounting_all_inversion_decomposition.csv"),
    "summary" => (:paper, "tables/ideological_universe_comparison.csv"),
    "ideology" => (:paper, "raw/ideology_k_gap_accounting_both_universes.csv"),
    "sets" => (:accounting, "raw/cabinet_party_set_accounting.csv"),
    "linkage" => (:accounting, "raw/cabinet_party_set_period_linkage.csv"),
    "bridge" => (:paper, "tables/table_appendix_cabinet_interval_bridge.csv"),
    "district" => (:accounting, "raw/district_accounting_all_years.csv"),
    "cabinet_district" => (:accounting, "tables/table_cabinet_district_concentration.csv"),
)

const SUMMARY_SPECS = [
    (; summary = "strongest-cabinet-inversion-within-adjusted-quota", metric = :within_adjusted_quota, aggregation = :identity,
       source = "cabinet", filters = (; case_domain = "cabinet"), selection = :lowest_vote_share),
    (; summary = "seat-winning-k0-totals", metric = :minimal_inversions, aggregation = :sum,
       source = "summary", filters = (; ideological_universe = "seat_winning", k = "0")),
    (; summary = "seat-winning-k0-totals", metric = :minimal_seat_majority_coalitions, aggregation = :sum,
       source = "summary", filters = (; ideological_universe = "seat_winning", k = "0")),
    (; summary = "all-parties-k0-totals", metric = :minimal_inversions, aggregation = :sum,
       source = "summary", filters = (; ideological_universe = "all_parties", k = "0")),
    (; summary = "seat-winning-k1-surviving-connected", metric = :count, aggregation = :sum,
       source = "ideology", filters = (; ideological_universe = "seat_winning", k = "1", gap_count = "0", minimal_seat_majority = "true")),
    (; summary = "seat-winning-k0-all-inversions", metric = :count, aggregation = :sum,
       source = "ideology", filters = (; ideological_universe = "seat_winning", k = "0", inversion = "true")),
    (; summary = "seat-winning-k1-negative-within", metric = :A_C, aggregation = :count_negative,
       source = "ideology", filters = (; ideological_universe = "seat_winning", k = "1", minimal_inversion = "true")),
    (; summary = "seat-winning-2014-k1-negative-within", metric = :A_C, aggregation = :count_negative,
       source = "ideology", filters = (; ideological_universe = "seat_winning", k = "1", minimal_inversion = "true", election = "2014")),
    (; summary = "seat-winning-2022-k1-negative-within", metric = :A_C, aggregation = :count_negative,
       source = "ideology", filters = (; ideological_universe = "seat_winning", k = "1", minimal_inversion = "true", election = "2022")),
    (; summary = "all-parties-k0-positive-within", metric = :A_C, aggregation = :count_positive,
       source = "ideology", filters = (; ideological_universe = "all_parties", k = "0", minimal_inversion = "true")),
    (; summary = "seat-winning-2014-k1-pt-membership", metric = :includes_PT, aggregation = :sum,
       source = "ideology", filters = (; election = "2014", ideological_universe = "seat_winning", k = "1", minimal_inversion = "true")),
    (; summary = "seat-winning-2022-k1-mdb-uniao-gapped", metric = :count, aggregation = :sum,
       source = "ideology", filters = (; election = "2022", ideological_universe = "seat_winning", k = "1", minimal_inversion = "true", left_endpoint = "MDB", right_endpoint = "UNIÃO", gap_count = "1")),
    (; summary = "cabinet-party-sets", metric = :count, aggregation = :sum,
       source = "sets", filters = NamedTuple()),
    (; summary = "cabinet-party-sets", metric = :d_C, aggregation = :count_positive,
       source = "sets", filters = NamedTuple()),
    (; summary = "cabinet-party-sets", metric = :d_C, aggregation = :count_negative,
       source = "sets", filters = NamedTuple()),
    (; summary = "cabinet-inversions", metric = :count, aggregation = :sum,
       source = "cabinet", filters = (; case_domain = "cabinet")),
    (; summary = "cabinet-inversions", metric = :numerical_vector_group, aggregation = :unique_count,
       source = "cabinet", filters = (; case_domain = "cabinet")),
    (; summary = "cabinet-component-signs", metric = :B_C, aggregation = :count_positive,
       source = "sets", filters = NamedTuple()),
    (; summary = "cabinet-component-signs", metric = :A_C, aggregation = :count_positive,
       source = "sets", filters = NamedTuple()),
    (; summary = "cabinet-closure-gaps", metric = :closure_gap_n, aggregation = :min,
       source = "bridge", filters = (; ideological_universe = "seat_winning")),
    (; summary = "cabinet-closure-gaps", metric = :closure_gap_n, aggregation = :max,
       source = "bridge", filters = (; ideological_universe = "seat_winning")),
    (; summary = "district-magnitude", metric = :S_d, aggregation = :median,
       source = "district", filters = (; election_year = "2014")),
    (; summary = "district-magnitude", metric = :S_d, aggregation = :mean,
       source = "district", filters = (; election_year = "2014")),
    (; summary = "eight-seat-districts", metric = :count, aggregation = :sum,
       source = "district", filters = (; election_year = "2014", S_d = "8")),
    (; summary = "seat-winning-2014-k0-other-inversions", metric = :count, aggregation = :sum_minus_one,
       source = "ideology", filters = (; election = "2014", ideological_universe = "seat_winning", k = "0", minimal_inversion = "true")),
    (; summary = "seat-winning-2014-k0-negative-between", metric = :B_C, aggregation = :count_negative,
       source = "ideology", filters = (; election = "2014", ideological_universe = "seat_winning", k = "0", minimal_inversion = "true")),
    (; summary = "cabinet-district-concentration", metric = :positive_count, aggregation = :min,
       source = "cabinet_district", filters = NamedTuple()),
    (; summary = "cabinet-district-concentration", metric = :positive_count, aggregation = :max,
       source = "cabinet_district", filters = NamedTuple()),
    (; summary = "cabinet-district-concentration", metric = :top_three_positive_share, aggregation = :min,
       source = "cabinet_district", filters = NamedTuple()),
    (; summary = "cabinet-district-concentration", metric = :top_three_positive_share, aggregation = :max,
       source = "cabinet_district", filters = NamedTuple()),
    (; summary = "cabinet-district-concentration", metric = :districts_for_ninety_pct, aggregation = :min,
       source = "cabinet_district", filters = NamedTuple()),
    (; summary = "cabinet-district-concentration", metric = :districts_for_ninety_pct, aggregation = :max,
       source = "cabinet_district", filters = NamedTuple()),
]

for universe in ("seat_winning", "all_parties"), k in ("0", "1"), election in ("all", "2014", "2018", "2022")
    filters = (; ideological_universe = universe, k,
        minimal_seat_majority = "true", inversion = "true")
    election == "all" || (filters = merge(filters, (; election)))
    push!(SUMMARY_SPECS, (; summary = DOMINANCE_SUMMARY, metric = :minimal_inversions,
        aggregation = :count, source = "ideology", filters))
    for metric in DOMINANCE_METRICS, aggregation in (:count, :percentage)
        push!(SUMMARY_SPECS, (; summary = DOMINANCE_SUMMARY, metric, aggregation,
            source = "ideology", filters))
    end
end

function load_summary_sources(paper_root, accounting_root)
    Dict(key => CSV.read(joinpath(location == :paper ? paper_root : accounting_root, path), DataFrame; types = (i, name) -> name in (:period, :cabinet_period) ? String : nothing)
         for (key, (location, path)) in SOURCE_FILES)
end

function summary_metric(row, metric)
    metric == :count && return 1
    metric == :minimal_inversions && hasproperty(row, :minimal_seat_majority) && return row.minimal_seat_majority && row.inversion
    metric == :A_C_gt_B_C && return row.A_C > row.B_C
    metric == :A_C_lt_B_C && return row.A_C < row.B_C
    metric == :A_C_eq_B_C && return row.A_C == row.B_C
    metric == :includes_PT && return "PT" in strip.(split(String(row.parties), ','))
    metric == :within_adjusted_quota && return row.q_C + row.A_C
    row[metric]
end

function aggregate_values(values, op)
    op == :count && return count(identity, values)
    # No percentage is defined for a zero denominator (all-party 2018 k=0).
    op == :percentage && return isempty(values) ? missing : 100 * count(identity, values) / length(values)
    isempty(values) && op in (:identity, :min, :max, :mean, :median) && return missing
    op == :identity && return only(values)
    op == :sum && return isempty(values) ? 0 : sum(values)
    op == :sum_minus_one && return sum(values) - 1
    op == :min && return minimum(values)
    op == :max && return maximum(values)
    op == :mean && return mean(values)
    op == :median && return median(values)
    op == :count_positive && return count(>(0), values)
    op == :count_negative && return count(<(0), values)
    op == :unique_count && return length(unique(values))
    error("Unsupported summary aggregation: $op")
end

"""Audit stored accounting and domain counts without recomputing decomposition or minimality."""
function audit_component_dominance(sources)
    ideology, domains = sources["ideology"], sources["summary"]
    keys = [:ideological_universe, :k, :election]
    expected = Set((u, k, y) for u in ("seat_winning", "all_parties") for k in (0, 1) for y in (2014, 2018, 2022))
    Set(Tuple(row) for row in eachrow(select(domains, keys))) == expected || error("Dominance domain-summary coverage mismatch")
    allunique(select(domains, keys)) || error("Duplicate dominance domain-summary key")
    Set(Tuple(row) for row in eachrow(unique(select(ideology, keys)))) == expected || error("Dominance accounting coverage mismatch")
    allunique(select(ideology, vcat(keys, [:coalition_id]))) || error("Duplicate ideological coalition key")
    max_residual = 0.0
    for row in eachrow(ideology)
        all(isfinite, (row.d_C, row.A_C, row.B_C)) || error("Nonfinite ideological component: $(row.coalition_id)")
        residual = abs(row.d_C - (row.A_C + row.B_C))
        residual <= DOMINANCE_ATOL || error("Dominance accounting identity d_C=A_C+B_C failed: $(row.coalition_id)")
        max_residual = max(max_residual, residual)
        row.minimal_inversion == (row.minimal_seat_majority && row.inversion) || error("Minimal-inversion conjunction mismatch: $(row.coalition_id)")
    end
    for domain in eachrow(domains)
        rows = filter(r -> all(r[key] == domain[key] for key in keys), ideology)
        nrow(rows) == domain.diagnostic_admissible_coalitions || error("Admissible coalition count disagrees with domain summary")
        count(identity, rows.minimal_seat_majority) == domain.minimal_seat_majority_coalitions || error("Minimal-winning count disagrees with domain summary")
        selected = filter(r -> r.minimal_seat_majority && r.inversion, rows)
        nrow(selected) == domain.minimal_inversions || error("Dominance denominator disagrees with domain summary: $(Tuple(domain[key] for key in keys))")
        counts = [count(r -> summary_metric(r, metric), eachrow(selected)) for metric in DOMINANCE_METRICS]
        sum(counts) == nrow(selected) || error("Dominance comparisons do not partition minimal inversions")
        all(count(metric -> summary_metric(r, metric), DOMINANCE_METRICS) == 1 for r in eachrow(selected)) || error("Dominance comparisons are not mutually exclusive")
    end
    primary = filter(r -> r.ideological_universe == "seat_winning" && r.k == 1 &&
        r.minimal_seat_majority && r.inversion, ideology)
    observed = Dict(y => count(==(y), primary.election) for y in (2014, 2018, 2022))
    observed == Dict(2014 => 46, 2018 => 42, 2022 => 12) && nrow(primary) == 100 ||
        error("Primary k=1 denominator regression: expected 100 (46/42/12), got $(nrow(primary)) ($observed)")
    (; accounting_rows = nrow(ideology), domain_groups = nrow(domains),
        primary_k1_inversions = nrow(primary), max_identity_residual = max_residual,
        absolute_tolerance = DOMINANCE_ATOL, relative_tolerance = 0)
end

function build_summaries(sources; specs = SUMMARY_SPECS)
    records = NamedTuple[]
    for spec in specs
        rows = filter(sources[spec.source]) do row
            all(string(row[key]) == value for (key, value) in pairs(spec.filters))
        end
        cabinet_source = spec.source in ("cabinet", "sets", "linkage", "bridge", "cabinet_district")
        isempty(rows) && spec.summary != DOMINANCE_SUMMARY && !cabinet_source && error("Empty source selection for $(spec.summary)")
        if get(spec, :selection, nothing) == :lowest_vote_share && !isempty(rows)
            rows = first(sort(rows, [:vote_share, :coalition_party_count, :case_id]), 1)
        end
        value = aggregate_values(collect(skipmissing([summary_metric(row, spec.metric) for row in eachrow(rows)])), spec.aggregation)
        location, file = SOURCE_FILES[spec.source]
        prefix = location == :paper ? "domains" : "accounting"
        push!(records, (; summary = spec.summary, metric = string(spec.metric),
            aggregation = string(spec.aggregation), value = string(value),
            source_file = "build/results/$prefix/$file",
            source_filter = isempty(spec.filters) ? "all rows" : join(["$k=$v" for (k, v) in pairs(spec.filters)], "; "),
            source_row_count = nrow(rows),
            selection = string(get(spec, :selection, :all_matching_rows)),
            result_status = ismissing(value) ? "unavailable" : "computed",
            ideological_universe = get(spec.filters, :ideological_universe, "not_applicable"),
            k = get(spec.filters, :k, "not_applicable"),
            election = get(spec.filters, :election, "all")))
    end
    result = DataFrame(records)
    allunique(select(result, SUMMARY_KEY)) || error("Duplicate summary key")
    result
end

function write_prose_summaries(output_root; paper_root)
    sources = load_summary_sources(paper_root, output_root)
    audit_component_dominance(sources)
    data = build_summaries(sources)
    relative = "tables/prose_analysis_summaries.csv"
    path = joinpath(output_root, relative)
    mkpath(dirname(path))
    CSV.write(path, data)
    [(; path = relative, artifact_type = "table",
        description = "Raw aggregates from existing analysis CSVs; summary/metric/aggregation/universe/k/election keys and upstream selections. No TeX or display values.",
        rows = nrow(data), columns = ncol(data), sha256 = bytes2hex(SHA.sha256(read(path))))]
end

end
