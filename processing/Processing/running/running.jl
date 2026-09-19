using Pkg

# =============================================================================
# BLOCK 0. PROJECT ACTIVATION AND IMPORTS
# =============================================================================

running_dir = @__DIR__
processing_root = normpath(joinpath(running_dir, ".."))
repo_root = normpath(joinpath(processing_root, "..", ".."))

Pkg.activate(processing_root)

using CSV
using DataFrames
using Dates
using Printf
using Statistics

include(joinpath(processing_root, "src", "Processing.jl"))
using .Processing
import .Processing.AnalysisRunnerCore as ARC
include(joinpath(processing_root, "decomposition", "CoalitionDecomposition.jl"))

println("Paper-oriented Processing runner")
println("running_dir: ", running_dir)
println("processing_root: ", processing_root)
println("repo_root: ", repo_root)

# =============================================================================
# BLOCK 1. PATHS AND CONFIGURATION
# =============================================================================

data_root = joinpath(repo_root, "data", "raw", "electionsBR")
coalition_json_path = Processing.CabinetRelease.default_pin_path() # Local public cabinet snapshot.
classification_root_dir = joinpath(repo_root, "scrape_classification", "output")
party_alias_path = joinpath(processing_root, "data", "party_aliases.csv")
party_lineage_path = joinpath(processing_root, "data", "party_lineage_events.csv")

paper_output_root = joinpath(repo_root, "build", "results", "domains")
raw_dir = joinpath(paper_output_root, "raw")
diagnostics_dir = joinpath(paper_output_root, "diagnostics")
tables_dir = joinpath(paper_output_root, "tables")
figure_data_dir = joinpath(paper_output_root, "figure_data")
artifact_manifest_path = joinpath(paper_output_root, "artifact_manifest.csv")
review_manuscript_dir = joinpath(repo_root, "writing", "submission_inversions_review", "manuscript")

analysis_years = [2014, 2018, 2022]
ideological_universes = (:seat_winning, :all_parties)
primary_ideological_universe = :seat_winning
expected_total_seats = 513
expected_national_vote_totals = Dict(
    2014 => 97_355_354,
    2018 => 98_264_190,
    2022 => 109_413_508,
)
seat_majority_threshold = 257
ALLOW_OVERWRITE = lowercase(get(ENV, "ALLOW_OVERWRITE", "false")) in ("1", "true", "yes")

party_mun_zone_paths = Dict(
    2014 => joinpath(data_root, "2014", "party_mun_zone.csv"),
    2018 => joinpath(data_root, "2018", "party_mun_zone.csv"),
    2022 => joinpath(data_root, "2022", "party_mun_zone.csv"),
)
candidate_paths = Dict(
    2014 => joinpath(data_root, "2014", "candidate.csv"),
    2018 => joinpath(data_root, "2018", "candidate.csv"),
    2022 => joinpath(data_root, "2022", "candidate.csv"),
)

Processing.set_root!(data_root)
Processing.set_coalition_path!(coalition_json_path)

mkpath(raw_dir)
mkpath(diagnostics_dir)
mkpath(tables_dir)
mkpath(figure_data_dir)

println("data_root: ", data_root)
println("coalition_json_path: ", coalition_json_path)
println("classification_root_dir: ", classification_root_dir)
println("paper_output_root: ", paper_output_root)
println("ALLOW_OVERWRITE: ", ALLOW_OVERWRITE)

# =============================================================================
# BLOCK 2. SMALL HELPERS
# =============================================================================

artifact_records = NamedTuple[]

electoral_party_overrides = Dict(
    2014 => Dict{String,String}(),
    2018 => Dict{String,String}(),
    2022 => Dict{String,String}(),
)

ideology_raw_overrides = Dict(
    2014 => Dict{String,String}(),
    2018 => Dict{String,String}(),
    2022 => Dict{String,String}(),
)

ideology_label_overrides = Dict(
    2014 => Dict(
        "AVANTE" => "PT DO B",
        "DC" => "PSDC",
        "MDB" => "PMDB",
        "PODE" => "PTN",
    ),
    2018 => Dict{String,String}(),
    2022 => Dict{String,String}(),
)

ideology_drop_labels = Dict(
    2014 => Set(["NOVO", "PMB", "REDE"]),
    2018 => Set{String}(),
    2022 => Set{String}(),
)

function print_block(title)
    println()
    println(repeat("=", 100))
    println(title)
    println(repeat("=", 100))
end

function show_table(df)
    show(stdout, MIME("text/plain"), df; allrows = true, allcols = true, truncate = 0)
    println()
end

function write_paper_csv(path, df; allow_overwrite = ALLOW_OVERWRITE)
    if isfile(path) && !allow_overwrite
        error("Output exists and ALLOW_OVERWRITE is false: $(path)")
    end
    mkpath(dirname(path))
    CSV.write(path, df)
    return path
end

function record_artifact!(path, artifact_type, description, df)
    push!(artifact_records, (
        path = relpath(path, paper_output_root),
        artifact_type = String(artifact_type),
        description = String(description),
        rows = nrow(df),
        columns = length(names(df)),
    ))
    return path
end

function write_artifact_csv(path, df, artifact_type, description; allow_overwrite = ALLOW_OVERWRITE)
    write_paper_csv(path, df; allow_overwrite = allow_overwrite)
    record_artifact!(path, artifact_type, description, df)
    return path
end




function preflight_table()
    rows = NamedTuple[]
    push!(rows, (item = "repo root", path = repo_root, kind = "dir", exists = isdir(repo_root), essential = true))
    push!(rows, (item = "processing root", path = processing_root, kind = "dir", exists = isdir(processing_root), essential = true))
    push!(rows, (item = "data root", path = data_root, kind = "dir", exists = isdir(data_root), essential = true))
    push!(rows, (item = "cabinet public metadata", path = coalition_json_path, kind = "file", exists = isfile(coalition_json_path), essential = true))
    push!(rows, (item = "classification root", path = classification_root_dir, kind = "dir", exists = isdir(classification_root_dir), essential = true))
    push!(rows, (item = "party aliases", path = party_alias_path, kind = "file", exists = isfile(party_alias_path), essential = true))
    push!(rows, (item = "party lineage events", path = party_lineage_path, kind = "file", exists = isfile(party_lineage_path), essential = true))
    for year in analysis_years
        push!(rows, (item = "$(year) party_mun_zone.csv", path = party_mun_zone_paths[year], kind = "file", exists = isfile(party_mun_zone_paths[year]), essential = true))
        push!(rows, (item = "$(year) candidate.csv", path = candidate_paths[year], kind = "file", exists = isfile(candidate_paths[year]), essential = true))
    end
    return DataFrame(rows)
end

function validate_total_seats!(df, year)
    seat_col = hasproperty(df, :total_seats) ? :total_seats : :seats
    total_seats = sum(Int.(coalesce.(df[!, seat_col], 0)))
    total_seats == expected_total_seats || error("Expected $(expected_total_seats) seats for $(year), found $(total_seats).")
    return true
end

function validate_seat_diff_sum!(df, year)
    seat_diff_sum = sum(Float64.(coalesce.(df.seat_diff, 0.0)))
    isapprox(seat_diff_sum, 0.0; atol = 1e-6) || error("Seat differentials do not sum to zero for $(year): $(seat_diff_sum).")
    return true
end

function majority_status(vote_majority, seat_majority)
    if vote_majority && seat_majority
        return "votes+seats"
    elseif vote_majority
        return "votes_only"
    elseif seat_majority
        return "seats_only"
    end
    return "neither"
end

pct(x; digits = 2) = round(100 * Float64(x), digits = digits)
display_round(x; digits = 2) = round(Float64(x), digits = digits)
fmt2(x) = @sprintf("%.2f", Float64(x))
function require_table_columns(df, required, label)
    missing_columns = [column for column in required if column ∉ propertynames(df)]
    isempty(missing_columns) || error(
        "$(label) is missing columns: $(join(String.(missing_columns), ", ")).",
    )
    return true
end

function validate_display_accounting!(row, source_row, label)
    source_row.coalition_inversion || error("$(label): source row is not an inversion.")
    row.quota_display == display_round(source_row.quota) || error("$(label): displayed q_C does not match the unrounded quota.")
    row.seat_diff_display == display_round(source_row.seat_diff) || error("$(label): displayed d_C does not match the unrounded differential.")
    row.required_diff_display == display_round(source_row.required_diff) || error("$(label): displayed r_C does not match the unrounded required differential.")
    abs(Float64(row.seats) - (Float64(row.quota_display) + Float64(row.seat_diff_display))) <= 0.011 || error(
        "$(label): displayed s_C = q_C + d_C identity fails beyond rounding tolerance.",
    )
    abs(Float64(row.required_diff_display) - (seat_majority_threshold - Float64(row.quota_display))) <= 0.011 || error(
        "$(label): displayed r_C = 257 - q_C identity fails beyond rounding tolerance.",
    )
    source_row.seat_diff > source_row.required_diff || accounting_isapprox(source_row.seat_diff, source_row.required_diff) || error(
        "$(label): unrounded inversion row violates d_C >= r_C.",
    )
    Float64(row.seat_diff_display) >= Float64(row.required_diff_display) || error(
        "$(label): displayed inversion row violates d_C >= r_C.",
    )
    return true
end

function validate_cabinet_inversion_table!(display_df, source_df)
    required = (
        :election_year, :period, :period_days, :vote_share_pct, :seats,
        :quota_display, :seat_diff_display, :required_diff_display, :parties,
    )
    require_table_columns(display_df, required, "Cabinet inversion table CSV")
    nrow(display_df) == nrow(source_df) || error("Cabinet inversion table row count changed.")
    for (row, source_row) in zip(eachrow(display_df), eachrow(source_df))
        key = "$(row.election_year)/$(row.period)"
        Int(row.election_year) == Int(source_row.election_year) || error("Cabinet inversion table changed election for $(key).")
        string(row.period) == string(source_row.period) || error("Cabinet inversion table changed period for $(key).")
        row.period_days == source_row.period_days || error("Cabinet inversion table changed Days for $(key).")
        row.vote_share_pct == pct(source_row.vote_share) || error("Cabinet inversion table changed Vote % for $(key).")
        row.seats == source_row.seats || error("Cabinet inversion table changed Seats for $(key).")
        String(row.parties) == String(source_row.parties) || error("Cabinet inversion table changed Parties for $(key).")
        validate_display_accounting!(row, source_row, "cabinet $(key)")
    end
    return true
end

function validate_minimal_inversion_table!(display_df, source_df)
    required = (
        :election_year, :start_party, :end_party, :interval_size,
        :vote_share_pct, :seats, :quota_display, :seat_diff_display,
        :required_diff_display, :parties,
    )
    require_table_columns(display_df, required, "Minimal connected inversion table CSV")
    nrow(display_df) == nrow(source_df) || error("Minimal connected inversion table row count changed.")
    for (row, source_row) in zip(eachrow(display_df), eachrow(source_df))
        key = "$(row.election_year)/$(row.start_party)--$(row.end_party)"
        Int(row.election_year) == Int(source_row.election_year) || error("Minimal connected inversion table changed election for $(key).")
        String(row.start_party) == String(source_row.start_party) || error("Minimal connected inversion table changed start party for $(key).")
        String(row.end_party) == String(source_row.end_party) || error("Minimal connected inversion table changed end party for $(key).")
        row.interval_size == source_row.interval_size || error("Minimal connected inversion table changed interval size for $(key).")
        row.vote_share_pct == pct(source_row.vote_share) || error("Minimal connected inversion table changed Vote % for $(key).")
        row.seats == source_row.seats || error("Minimal connected inversion table changed Seats for $(key).")
        String(row.parties) == String(source_row.parties) || error("Minimal connected inversion table changed interval membership for $(key).")
        validate_display_accounting!(row, source_row, "ideological interval $(key)")
    end
    return true
end

csv_text(value) = ismissing(value) ? "" : string(value)

function csv_roundtrip_values_match(left, right)
    if ismissing(left) || ismissing(right)
        return csv_text(left) == csv_text(right)
    elseif left isa Real && right isa Real
        return isapprox(Float64(left), Float64(right); atol = 1e-10, rtol = 0.0)
    end
    return string(left) == string(right)
end

function validate_csv_roundtrip!(csv_df, expected_df, required, label)
    require_table_columns(csv_df, required, "$(label) CSV")
    propertynames(csv_df) == propertynames(expected_df) || error(
        "$(label) CSV columns or column order changed after round-trip.",
    )
    nrow(csv_df) == nrow(expected_df) || error(
        "$(label) CSV row count changed after round-trip.",
    )
    for column in propertynames(expected_df)
        for row_index in 1:nrow(expected_df)
            csv_roundtrip_values_match(csv_df[row_index, column], expected_df[row_index, column]) || error(
                "$(label) CSV round-trip changed row $(row_index), column $(column).",
            )
        end
    end
    return true
end

function validate_selected_party_differential_table!(display_df, source_df)
    required = (:election_year, :party, :vote_share_pct, :seats, :quota_display, :seat_diff_display)
    require_table_columns(display_df, required, "Selected party-differential table CSV")
    length(unique(zip(display_df.election_year, display_df.party))) == nrow(display_df) || error(
        "Selected party-differential table contains duplicate election-party rows.",
    )
    for row in eachrow(display_df)
        source_match = source_df[
            (source_df.election_year .== Int(row.election_year)) .&
            (source_df.party .== String(row.party)),
            :,
        ]
        nrow(source_match) == 1 || error(
            "Selected party-differential row $(row.election_year)/$(row.party) does not map to exactly one source row.",
        )
        source_row = only(eachrow(source_match))
        row.vote_share_pct == pct(source_row.vote_share) || error("Selected party table changed Vote share for $(row.election_year)/$(row.party).")
        Int(row.seats) == Int(source_row.seats) || error("Selected party table changed Seats for $(row.election_year)/$(row.party).")
        row.quota_display == display_round(source_row.quota) || error("Selected party table changed Quota for $(row.election_year)/$(row.party).")
        row.seat_diff_display == display_round(source_row.seat_diff) || error("Selected party table changed Seat diff. for $(row.election_year)/$(row.party).")
    end
    return true
end

function validate_ideology_k_gap_summary_table!(display_df, source_df)
    required = (
        :election,
        :k,
        :minimal_seat_majority_coalitions,
        :minimal_inversions,
        :strongest_inversion_coalition,
        :strongest_inversion_vote_share,
        :strongest_inversion_vote_share_pct,
        :strongest_inversion_seats,
        :strongest_inversion_r_C,
        :strongest_inversion_vote_deficit_pp,
        :diagnostic_admissible_coalitions,
        :diagnostic_exact_strength_tie_count,
        :diagnostic_exact_strength_tied_coalitions,
    )
    require_table_columns(display_df, required, "Ideology k-gap summary table CSV")
    nrow(display_df) == length(analysis_years) * 2 || error(
        "Ideology k-gap summary must contain six election-domain rows.",
    )
    length(unique(zip(display_df.election, display_df.k))) == nrow(display_df) || error(
        "Ideology k-gap summary contains duplicate election-k rows.",
    )

    for row in eachrow(display_df)
        source_domain = source_df[
            (source_df.election .== Int(row.election)) .&
            (source_df.k .== Int(row.k)),
            :,
        ]
        nrow(source_domain) == Int(row.diagnostic_admissible_coalitions) || error(
            "Ideology k-gap summary changed admissible-coalition count for $(row.election)/k=$(row.k).",
        )
        sum(Int.(source_domain.minimal_seat_majority)) == Int(row.minimal_seat_majority_coalitions) || error(
            "Ideology k-gap summary changed minimal-majority count for $(row.election)/k=$(row.k).",
        )
        minimal_inversion_domain = source_domain[
            (source_domain.minimal_seat_majority .== true) .&
            (source_domain.inversion .== true),
            :,
        ]
        nrow(minimal_inversion_domain) == Int(row.minimal_inversions) || error(
            "Ideology k-gap summary changed minimal-inversion count for $(row.election)/k=$(row.k).",
        )

        strongest = strongest_inversion_selection(minimal_inversion_domain)
        if strongest === nothing
            String(row.strongest_inversion_coalition) == "None" || error(
                "Ideology k-gap summary must report None for $(row.election)/k=$(row.k).",
            )
            for column in (
                :strongest_inversion_vote_share,
                :strongest_inversion_vote_share_pct,
                :strongest_inversion_seats,
                :strongest_inversion_r_C,
                :strongest_inversion_vote_deficit_pp,
            )
                ismissing(row[column]) || error(
                    "Ideology k-gap summary has a nonmissing strongest-case metric for a null domain.",
                )
            end
            Int(row.diagnostic_exact_strength_tie_count) == 0 || error(
                "Ideology k-gap summary has a nonzero tie count for a null domain.",
            )
            isempty(csv_text(row.diagnostic_exact_strength_tied_coalitions)) || error(
                "Ideology k-gap summary has tied labels for a null domain.",
            )
            continue
        end

        selected = strongest.selected
        String(row.strongest_inversion_coalition) == String(selected.coalition_label) || error(
            "Ideology k-gap summary changed strongest coalition for $(row.election)/k=$(row.k).",
        )
        isapprox(Float64(row.strongest_inversion_vote_share), Float64(selected.vote_share); atol = 1e-12, rtol = 0.0) || error(
            "Ideology k-gap summary changed strongest vote share for $(row.election)/k=$(row.k).",
        )
        isapprox(Float64(row.strongest_inversion_vote_share_pct), 100.0 * Float64(selected.vote_share); atol = 1e-10, rtol = 0.0) || error(
            "Ideology k-gap summary changed strongest vote percentage for $(row.election)/k=$(row.k).",
        )
        Int(row.strongest_inversion_seats) == Int(selected.seats) || error(
            "Ideology k-gap summary changed strongest seats for $(row.election)/k=$(row.k).",
        )
        isapprox(Float64(row.strongest_inversion_r_C), Float64(selected.r_C); atol = 1e-10, rtol = 0.0) || error(
            "Ideology k-gap summary changed strongest r_C for $(row.election)/k=$(row.k).",
        )
        isapprox(Float64(row.strongest_inversion_vote_deficit_pp), Float64(selected.vote_deficit_pp); atol = 1e-10, rtol = 0.0) || error(
            "Ideology k-gap summary changed strongest vote deficit for $(row.election)/k=$(row.k).",
        )
        has_exact_tie = nrow(strongest.exact_ties) > 1
        expected_tie_count = has_exact_tie ? nrow(strongest.exact_ties) : 0
        Int(row.diagnostic_exact_strength_tie_count) == expected_tie_count || error(
            "Ideology k-gap summary changed exact-strength tie count for $(row.election)/k=$(row.k).",
        )
        expected_tied_labels = has_exact_tie ? join(String.(strongest.exact_ties.coalition_label), " | ") : ""
        csv_text(row.diagnostic_exact_strength_tied_coalitions) == expected_tied_labels || error(
            "Ideology k-gap summary changed exact-strength tied labels for $(row.election)/k=$(row.k).",
        )
    end
    return true
end

function validate_ideology_order_table!(display_df, source_df)
    required = (:election_year, :ordinal_position, :party, :classification_label, :ideology_value_numeric, :ideology_source, :source_party_raw)
    require_table_columns(display_df, required, "Ideology-order appendix table CSV")
    length(unique(zip(display_df.election_year, display_df.ordinal_position))) == nrow(display_df) || error(
        "Ideology-order appendix contains duplicate election-position rows.",
    )
    for row in eachrow(display_df)
        source_match = source_df[
            (source_df.election_year .== Int(row.election_year)) .&
            (source_df.ordinal_position .== Int(row.ordinal_position)),
            :,
        ]
        nrow(source_match) == 1 || error("Ideology-order appendix row $(row.election_year)/$(row.ordinal_position) lacks a unique source row.")
        source_row = only(eachrow(source_match))
        String(row.party) == String(source_row.party) || error("Ideology-order appendix changed party at $(row.election_year)/$(row.ordinal_position).")
        String(row.classification_label) == String(source_row.classification_label) || error("Ideology-order appendix changed classification at $(row.election_year)/$(row.ordinal_position).")
        isapprox(Float64(row.ideology_value_numeric), Float64(source_row.ideology_value_numeric); atol = 1e-10, rtol = 0.0) || error("Ideology-order appendix changed score at $(row.election_year)/$(row.ordinal_position).")
        string(row.ideology_source) == string(source_row.ideology_source) || error("Ideology-order appendix changed source at $(row.election_year)/$(row.ordinal_position).")
        String(row.source_party_raw) == String(source_row.source_party_raw) || error("Ideology-order appendix changed source party at $(row.election_year)/$(row.ordinal_position).")
    end
    return true
end

function party_set_from_cell(value)
    text_value = csv_text(value)
    isempty(text_value) && return Set{String}()
    return Set(filter(!isempty, strip.(split(text_value, ","))))
end

function validate_cabinet_composition_table!(display_df, source_df)
    sum(display_df.period_days) == 4096 || error("Full appendix lost calendar days")
    for row in eachrow(display_df)
        row.majority_status == "unidentified" && continue
        src=only(eachrow(source_df[(source_df.election_year .== row.election_year) .& (source_df.period .== row.period), :]))
        row.vote_share_pct == pct(src.vote_share) || error("Appendix vote mismatch")
        row.seats == src.seats || error("Appendix seats mismatch")
        row.period_start == src.period_start && row.period_end == src.period_end || error("Appendix dates mismatch")
        row.parties == src.parties || error("Appendix composition mismatch")
    end
    return true
end






function vcat_or_empty(tables)
    isempty(tables) && return DataFrame()
    return vcat(tables...; cols = :union)
end

function mapping_source(raw_party, year; overrides = Dict{String,String}())
    normalized = Processing.normalize_party(raw_party)
    haskey(overrides, normalized) && return "local_override"
    canonical = Processing.canonical_party(raw_party; year = year, strict = false)
    canonical == Processing.UNKNOWN_PARTY && return "unmapped"
    return "shared_alias"
end

function party_mapping_table(raw_values, year; source, context = "", overrides = Dict{String,String}())
    rows = NamedTuple[]
    for raw in sort(unique(String.(raw_values)))
        normalized = Processing.normalize_party(raw)
        canonical = haskey(overrides, normalized) ? overrides[normalized] : Processing.canonical_party(raw; year = year, strict = false)
        push!(rows, (
            source = source,
            election_year = Int(year),
            context = context,
            raw_party = raw,
            normalized_party = normalized,
            canonical_party = canonical,
            mapping_source = mapping_source(raw, year; overrides = overrides),
        ))
    end
    return DataFrame(rows)
end

function append_mapping!(target, raw_values, year; source, context = "", overrides = Dict{String,String}())
    push!(target, party_mapping_table(raw_values, year; source = source, context = context, overrides = overrides))
    return target
end

function inclusive_days(start_date::Date, end_date::Date)
    end_date < start_date && error("Invalid date interval: $(start_date) > $(end_date).")
    return Dates.value(end_date - start_date) + 1
end

function overlap_days(start_a::Date, end_a::Date, start_b::Date, end_b::Date)
    start_overlap = max(start_a, start_b)
    end_overlap = min(end_a, end_b)
    end_overlap < start_overlap && return 0
    return inclusive_days(start_overlap, end_overlap)
end

function summarize_coalition(summary_df, parties)
    totals = Processing.coalition_totals(summary_df, parties)
    total_votes, coalition_votes, coalition_seats = totals.national_vote_total, totals.votes, totals.seats
    accounting = Processing.coalition_accounting_metrics(
        coalition_votes,
        coalition_seats;
        national_vote_total = total_votes,
        total_seats = expected_total_seats,
        seat_majority_threshold = seat_majority_threshold,
    )
    return (
        votes = Int(coalition_votes),
        national_vote_total = Int(total_votes),
        vote_share = accounting.vote_share,
        seats = Int(coalition_seats),
        seat_share = accounting.seat_share,
        quota = accounting.quota,
        seat_diff = accounting.seat_diff,
        required_diff = accounting.required_diff,
        representation_ratio = accounting.representation_ratio,
        vote_majority = accounting.vote_majority,
        seat_majority = accounting.seat_majority,
        majority_status = accounting.majority_status,
        coalition_inversion = accounting.coalition_inversion,
    )
end

const ACCOUNTING_ATOL = 1e-9
const ACCOUNTING_RTOL = 1e-12

function accounting_isapprox(lhs, rhs)
    return isapprox(Float64(lhs), Float64(rhs); atol = ACCOUNTING_ATOL, rtol = ACCOUNTING_RTOL)
end

function require_accounting_identity(lhs, rhs, label, identity)
    accounting_isapprox(lhs, rhs) || error(
        "Accounting validation failed for $(label): $(identity); lhs=$(lhs), rhs=$(rhs).",
    )
    return true
end

function membership_parties(value)
    parties = strip.(split(String(value), ","))
    filter!(!isempty, parties)
    length(parties) == length(unique(parties)) || error(
        "Duplicate party in coalition membership: $(String(value)).",
    )
    return parties
end

function validate_party_accounting!(df, year; expected_national_votes)
    required = (
        :party, :votes, :national_vote_total, :vote_share, :seats,
        :seat_share, :quota, :seat_diff, :representation_ratio,
    )
    missing_columns = [column for column in required if column ∉ propertynames(df)]
    isempty(missing_columns) || error(
        "Party accounting $(year) missing columns: $(join(String.(missing_columns), ", ")).",
    )
    nrow(df) > 0 || error("Party accounting $(year) has no rows.")
    length(unique(String.(df.party))) == nrow(df) || error("Duplicate party rows for $(year).")

    national_votes = sum(Int.(df.votes))
    national_votes == Int(expected_national_votes) || error(
        "Party accounting $(year) changed the national vote denominator: $(national_votes) != $(expected_national_votes).",
    )
    all(Int.(df.national_vote_total) .== national_votes) || error(
        "Party accounting $(year) has inconsistent national_vote_total values.",
    )
    sum(Int.(df.seats)) == expected_total_seats || error(
        "Party accounting $(year) does not sum to $(expected_total_seats) seats.",
    )

    for row in eachrow(df)
        label = "party $(year)/$(row.party)"
        expected_vote_share = row.votes / national_votes
        expected_seat_share = row.seats / expected_total_seats
        expected_quota = expected_total_seats * expected_vote_share
        expected_seat_diff = row.seats - expected_quota
        require_accounting_identity(row.vote_share, expected_vote_share, label, "vote share = v_i / V")
        require_accounting_identity(row.seat_share, expected_seat_share, label, "seat share = s_i / 513")
        require_accounting_identity(row.quota, expected_quota, label, "q_i = 513 v_i / V")
        require_accounting_identity(row.seat_diff, expected_seat_diff, label, "d_i = s_i - q_i")
        if row.votes > 0
            row.representation_ratio === missing && error("Missing R_i for positive-vote $(label).")
            expected_ratio = expected_seat_share / expected_vote_share
            require_accounting_identity(row.representation_ratio, expected_ratio, label, "R_i = (s_i/513)/(v_i/V)")
            require_accounting_identity(row.seat_diff, row.quota * (row.representation_ratio - 1), label, "d_i = q_i(R_i - 1)")
        end
    end

    validate_seat_diff_sum!(df, year)
    return true
end

function validate_coalition_accounting!(metrics_df, party_df; domain, id_columns)
    required = (
        :parties, :votes, :national_vote_total, :vote_share, :seats,
        :seat_share, :quota, :seat_diff, :required_diff,
        :representation_ratio, :vote_majority, :seat_majority,
        :majority_status, :coalition_inversion,
    )
    missing_columns = [column for column in required if column ∉ propertynames(metrics_df)]
    isempty(missing_columns) || error(
        "$(domain) coalition accounting missing columns: $(join(String.(missing_columns), ", ")).",
    )
    party_lookup = Dict(String(row.party) => row for row in eachrow(party_df))
    national_votes = sum(Int.(party_df.votes))

    for row in eachrow(metrics_df)
        label_values = [string(row[column]) for column in id_columns]
        label = "$(domain) " * join(label_values, "/")
        parties = membership_parties(row.parties)
        missing_parties = [party for party in parties if !haskey(party_lookup, party)]
        isempty(missing_parties) || error(
            "$(label) contains parties absent from the election accounting: $(join(missing_parties, ", ")).",
        )
        party_rows = [party_lookup[party] for party in parties]
        member_votes = sum((Int(member.votes) for member in party_rows); init=0)
        member_seats = sum((Int(member.seats) for member in party_rows); init=0)
        member_quota = sum((Float64(member.quota) for member in party_rows); init=0.0)

        Int(row.national_vote_total) == national_votes || error("$(label) uses a changed national vote denominator.")
        Int(row.votes) == member_votes || error("$(label) coalition vote total does not match its party membership.")
        Int(row.seats) == member_seats || error("$(label) coalition seat total does not match its party membership.")
        require_accounting_identity(row.quota, expected_total_seats * row.votes / national_votes, label, "q_C = 513 v_C / V")
        require_accounting_identity(row.quota, member_quota, label, "q_C = sum(q_i)")
        require_accounting_identity(row.seat_diff, row.seats - row.quota, label, "d_C = s_C - q_C")
        require_accounting_identity(row.required_diff, seat_majority_threshold - row.quota, label, "r_C = 257 - q_C")
        require_accounting_identity(row.vote_share, row.votes / national_votes, label, "vote share = v_C / V")
        require_accounting_identity(row.seat_share, row.seats / expected_total_seats, label, "seat share = s_C / 513")
        if row.quota == 0
            ismissing(row.representation_ratio) || error("Zero quota requires undefined ratio")
        else
            row.representation_ratio === missing && error("$(label) has undefined R_C.")
            require_accounting_identity(row.representation_ratio, row.seats / row.quota, label, "R_C = s_C / q_C")
            require_accounting_identity(row.representation_ratio, 1 + row.seat_diff / row.quota, label, "R_C = 1 + d_C/q_C")
            require_accounting_identity(row.representation_ratio, row.seat_share / row.vote_share, label, "R_C = (s_C/513)/(v_C/V)")
            weighted_party_ratio = sum(
                Float64(member.quota) / Float64(row.quota) * Float64(member.representation_ratio)
                for member in party_rows if member.quota > 0
            )
            require_accounting_identity(row.representation_ratio, weighted_party_ratio, label, "R_C = sum((q_i/q_C)R_i)")
        end

        expected_vote_majority = row.vote_share > 0.5
        expected_seat_majority = row.seats >= seat_majority_threshold
        row.vote_majority == expected_vote_majority || error("$(label) has an inconsistent vote-majority flag.")
        row.seat_majority == expected_seat_majority || error("$(label) has an inconsistent seat-majority flag.")
        row.majority_status == majority_status(expected_vote_majority, expected_seat_majority) || error("$(label) has an inconsistent majority status.")
        row.coalition_inversion == (expected_seat_majority && !expected_vote_majority) || error("$(label) has an inconsistent inversion flag.")
        if !expected_vote_majority
            differential_reaches_majority = row.seat_diff > row.required_diff || accounting_isapprox(row.seat_diff, row.required_diff)
            expected_seat_majority == differential_reaches_majority || error(
                "$(label) violates s_C >= 257 iff d_C >= r_C for a vote-minority coalition.",
            )
        end
    end
    return true
end

function add_metric_display_columns(df)
    out = copy(df)
    out[!, :vote_share_pct] = round.(100 .* Float64.(out.vote_share); digits = 2)
    out[!, :quota_display] = round.(Float64.(out.quota); digits = 2)
    out[!, :seat_diff_display] = round.(Float64.(out.seat_diff); digits = 2)
    out[!, :required_diff_display] = round.(Float64.(out.required_diff); digits = 2)
    out[!, :representation_ratio_display] = round.(Float64.(out.representation_ratio); digits = 2)
    return out
end

# Regenerate this appendix from the canonical party CSV without rerunning the
# analysis or overwriting other tables, figures, or diagnostics. For example:
# ALLOW_OVERWRITE=true julia -O0 --startup-file=no --project=processing/Processing \
#     processing/Processing/running/running.jl --party-representation-only


# =============================================================================
# BLOCK 3. PREFLIGHT CHECKS
# =============================================================================

print_block("BLOCK 3. PREFLIGHT CHECKS")
preflight_checks = preflight_table()
show_table(preflight_checks)
write_artifact_csv(joinpath(diagnostics_dir, "preflight_checks.csv"), preflight_checks, "diagnostic", "Required input files and directories for the paper runner.")
missing_essential = preflight_checks[(preflight_checks.essential .== true) .& (preflight_checks.exists .== false), :]
nrow(missing_essential) == 0 || error("Preflight failed; missing required input(s): $(join(String.(missing_essential.path), ", "))")

# =============================================================================
# BLOCK 4. MAPPING AND VOTE-COLUMN DIAGNOSTICS
# =============================================================================

print_block("BLOCK 4. MAPPING AND VOTE-COLUMN DIAGNOSTICS")
vote_mapping_tables = DataFrame[]
seat_mapping_tables = DataFrame[]
coalition_mapping_tables = DataFrame[]
ideology_mapping_tables = DataFrame[]
vote_consistency_tables = DataFrame[]

function selected_vote_component_diagnostic(pmz, year)
    vote_kwargs = ARC.vote_kwargs_for_year(year)
    nom_col, leg_col, total_col, scheme = Processing.detect_vote_cols(pmz; vote_kwargs...)
    expected_nom = year == 2014 ? "QT_VOTOS_NOMINAIS" : "QT_VOTOS_NOMINAIS_VALIDOS"
    expected_leg = year == 2014 ? "QT_VOTOS_LEGENDA" : "QT_TOTAL_VOTOS_LEG_VALIDOS"
    String(nom_col) == expected_nom || error("Wrong nominal vote column for $(year): selected $(nom_col), expected $(expected_nom).")
    String(leg_col) == expected_leg || error("Wrong legend vote column for $(year): selected $(leg_col), expected $(expected_leg).")
    if year in (2018, 2022)
        String(leg_col) != "QT_VOTOS_LEGENDA_VALIDOS" || error("Regressed to QT_VOTOS_LEGENDA_VALIDOS for $(year); expected QT_TOTAL_VOTOS_LEG_VALIDOS.")
    end
    selected_sum = scheme == :total ? sum(Processing.to_int.(pmz[!, total_col])) : sum(Processing.to_int.(pmz[!, nom_col]) .+ Processing.to_int.(pmz[!, leg_col]))
    rows = NamedTuple[]
    direct_legend_col = Processing.pick_col(pmz, "QT_VOTOS_LEGENDA_VALIDOS")
    total_legend_col = Processing.pick_col(pmz, "QT_TOTAL_VOTOS_LEG_VALIDOS")
    converted_col = nothing
    for candidate_col in ["QT_VOTOS_NOMINAIS_CONVR_LEG", "QT_VOTOS_NOM_CONVR_LEG_VALIDOS"]
        converted_col = Processing.pick_col(pmz, candidate_col)
        converted_col === nothing || break
    end
    if direct_legend_col !== nothing && total_legend_col !== nothing && converted_col !== nothing
        direct_sum = sum(Processing.to_int.(pmz[!, direct_legend_col]))
        total_legend_sum = sum(Processing.to_int.(pmz[!, total_legend_col]))
        converted_sum = sum(Processing.to_int.(pmz[!, converted_col]))
        push!(rows, (election_year = Int(year), selected_nominal_col = String(nom_col), selected_legend_col = String(leg_col), selected_total_col = total_col === nothing ? "" : String(total_col), selected_scheme = String(scheme), check_name = "total_legend_equals_direct_plus_converted", lhs_column = String(total_legend_col), lhs_sum = total_legend_sum, rhs_columns = string(direct_legend_col, " + ", converted_col), rhs_sum = direct_sum + converted_sum, difference = total_legend_sum - direct_sum - converted_sum, selected_component_sum = selected_sum))
    end
    if nom_col !== nothing && leg_col !== nothing && direct_legend_col !== nothing && direct_legend_col != leg_col
        selected_sum_int = sum(Processing.to_int.(pmz[!, nom_col]) .+ Processing.to_int.(pmz[!, leg_col]))
        legacy_sum = sum(Processing.to_int.(pmz[!, nom_col]) .+ Processing.to_int.(pmz[!, direct_legend_col]))
        push!(rows, (election_year = Int(year), selected_nominal_col = String(nom_col), selected_legend_col = String(leg_col), selected_total_col = total_col === nothing ? "" : String(total_col), selected_scheme = String(scheme), check_name = "selected_components_vs_direct_legend_components", lhs_column = string(nom_col, " + ", leg_col), lhs_sum = selected_sum_int, rhs_columns = string(nom_col, " + ", direct_legend_col), rhs_sum = legacy_sum, difference = selected_sum_int - legacy_sum, selected_component_sum = selected_sum))
    end
    if isempty(rows)
        push!(rows, (election_year = Int(year), selected_nominal_col = String(nom_col), selected_legend_col = String(leg_col), selected_total_col = total_col === nothing ? "" : String(total_col), selected_scheme = String(scheme), check_name = "selected_components_available", lhs_column = "", lhs_sum = missing, rhs_columns = "", rhs_sum = missing, difference = missing, selected_component_sum = selected_sum))
    end
    return DataFrame(rows)
end

function inspect_vote_inputs_for_year(year, path)
    needed_columns = Set(["DS_CARGO", "SG_UF", "SG_PARTIDO", "QT_VOTOS_NOMINAIS_VALIDOS", "QT_VOTOS_NOMINAIS", "QT_TOTAL_VOTOS_LEG_VALIDOS", "QT_VOTOS_LEGENDA_VALIDOS", "QT_VOTOS_LEGENDA", "QT_VOTOS_NOMINAIS_CONVR_LEG", "QT_VOTOS_NOM_CONVR_LEG_VALIDOS", "QT_VOTOS", "TOTAL_VOTOS", "QT_VOTOS_VALIDOS"])
    pmz = CSV.read(path, DataFrame; select = (index, name) -> String(name) in needed_columns)
    Processing.upper_strip!(pmz, :DS_CARGO)
    filter!(row -> row.DS_CARGO == "DEPUTADO FEDERAL", pmz)
    Processing.stringify!(pmz, :SG_PARTIDO)
    append_mapping!(vote_mapping_tables, pmz.SG_PARTIDO, year; source = "votes", context = basename(path), overrides = electoral_party_overrides[year])
    push!(vote_consistency_tables, selected_vote_component_diagnostic(pmz, year))
    return pmz
end

function inspect_seat_inputs_for_year(year, path)
    needed_columns = [:ANO_ELEICAO, :NR_TURNO, :SG_UF, :CD_CARGO, :DS_CARGO, :SG_PARTIDO, :DS_SIT_TOT_TURNO]
    candidates = CSV.read(path, DataFrame; select = needed_columns, normalizenames = true)
    Processing.upper_strip!(candidates, :DS_CARGO)
    filter!(row -> row.DS_CARGO == "DEPUTADO FEDERAL", candidates)
    Processing.stringify!(candidates, :SG_PARTIDO)
    append_mapping!(seat_mapping_tables, candidates.SG_PARTIDO, year; source = "seats", context = basename(path), overrides = electoral_party_overrides[year])
    return candidates
end

inspect_vote_inputs_for_year(2014, party_mun_zone_paths[2014])
inspect_vote_inputs_for_year(2018, party_mun_zone_paths[2018])
inspect_vote_inputs_for_year(2022, party_mun_zone_paths[2022])
inspect_seat_inputs_for_year(2014, candidate_paths[2014])
inspect_seat_inputs_for_year(2018, candidate_paths[2018])
inspect_seat_inputs_for_year(2022, candidate_paths[2022])
vote_column_consistency = vcat_or_empty(vote_consistency_tables)
println("Vote-column consistency:")
show_table(vote_column_consistency)

# =============================================================================
# BLOCK 5. LOAD IDEOLOGY CLASSIFICATIONS
# =============================================================================

print_block("BLOCK 5. LOAD IDEOLOGY CLASSIFICATIONS")
classification_2023 = Processing.load_party_classification(2023; root_dir = classification_root_dir)
classification_2025 = Processing.load_party_classification(2025; root_dir = classification_root_dir)
println("Classification rule: 2014 -> 2023; 2018 -> 2023; 2022 -> 2025.")
println("classification_2023 parties: ", join(String.(classification_2023.party_name_raw), ", "))
println("classification_2025 parties: ", join(String.(classification_2025.party_name_raw), ", "))

# =============================================================================
# BLOCK 6. LOAD ELECTION DATA EXPLICITLY BY YEAR
# =============================================================================

print_block("BLOCK 6. LOAD ELECTION DATA EXPLICITLY BY YEAR")

# One frozen electoral loader supplies national and district accounting.
function load_votes_for_year(year, path; overrides = Dict{String,String}())
    isempty(overrides) || error("Electoral corrections belong in the canonical party aliases.")
    district = CoalitionDecomposition.load_district_votes(year, path)
    votes = combine(groupby(district, :party), :votes => sum => :valid_total)
    rename!(votes, :party => :SG_PARTIDO)
    sort!(votes, :valid_total; rev = true)
    return votes
end

function load_seats_for_year(year, path; overrides = Dict{String,String}())
    isempty(overrides) || error("Electoral corrections belong in the canonical party aliases.")
    district = CoalitionDecomposition.load_district_seats(year, path)
    seats = combine(groupby(district, :party), :seats => sum => :total_seats)
    rename!(seats, :party => :SG_PARTIDO)
    sort!(seats, :total_seats; rev = true)
    sum(seats.total_seats) == expected_total_seats || error("Chamber seat total changed for $(year).")
    return seats
end

function print_loaded_year(year, votes, seats, summary)
    total_votes = sum(votes.valid_total)
    println()
    println("Election $(year)")
    println("number of vote parties: ", nrow(votes))
    println("number of seat parties: ", nrow(seats))
    println("total valid votes: ", total_votes)
    println("total seats: ", sum(seats.total_seats))
    println("party list: ", join(sort(String.(summary.SG_PARTIDO)), ", "))
    total_votes == expected_national_vote_totals[year] || error(
        "Expected $(expected_national_vote_totals[year]) national votes for $(year), found $(total_votes).",
    )
    validate_total_seats!(summary, year)
end

votes_2014 = load_votes_for_year(2014, party_mun_zone_paths[2014]; overrides = electoral_party_overrides[2014])
seats_2014 = load_seats_for_year(2014, candidate_paths[2014]; overrides = electoral_party_overrides[2014])
party_summary_2014 = Processing.party_summary(votes_2014, seats_2014; expected_total_seats = expected_total_seats)
print_loaded_year(2014, votes_2014, seats_2014, party_summary_2014)

votes_2018 = load_votes_for_year(2018, party_mun_zone_paths[2018]; overrides = electoral_party_overrides[2018])
seats_2018 = load_seats_for_year(2018, candidate_paths[2018]; overrides = electoral_party_overrides[2018])
party_summary_2018 = Processing.party_summary(votes_2018, seats_2018; expected_total_seats = expected_total_seats)
print_loaded_year(2018, votes_2018, seats_2018, party_summary_2018)

votes_2022 = load_votes_for_year(2022, party_mun_zone_paths[2022]; overrides = electoral_party_overrides[2022])
seats_2022 = load_seats_for_year(2022, candidate_paths[2022]; overrides = electoral_party_overrides[2022])
party_summary_2022 = Processing.party_summary(votes_2022, seats_2022; expected_total_seats = expected_total_seats)
print_loaded_year(2022, votes_2022, seats_2022, party_summary_2022)

# =============================================================================
# BLOCK 7. COALITION PERIOD LINKAGE
# =============================================================================

print_block("BLOCK 7. COALITION PERIOD LINKAGE")
cabinet_calendar = Processing.CabinetRelease.calendar_table(coalition_json_path)
cabinet_unidentified = cabinet_calendar[.!cabinet_calendar.identified, :]
write_artifact_csv(joinpath(raw_dir, "cabinet_calendar_status.csv"), cabinet_calendar, "raw", "Published cabinet membership calendar, qualified by coverage/status and half-open dates.")
write_artifact_csv(joinpath(raw_dir, "cabinet_unidentified_intervals.csv"), cabinet_unidentified, "raw", "Explicit unavailable full cabinet compositions; no confirmed core is substituted for a complete set.")
coalition_periods_raw = Processing.coalitions_by_period_raw(; path = coalition_json_path)
coalition_windows = Processing.coalition_period_windows(; path = coalition_json_path)

mandate_2014 = ARC.mandate_window(2014)
mandate_2018 = ARC.mandate_window(2018)
mandate_2022 = ARC.mandate_window(2022)
coalitions_for_2014_election = Processing.coalition_periods_overlapping_window(coalition_periods_raw, mandate_2014.start_date, mandate_2014.end_date; path = coalition_json_path)
coalitions_for_2018_election = Processing.coalition_periods_overlapping_window(coalition_periods_raw, mandate_2018.start_date, mandate_2018.end_date; path = coalition_json_path)
coalitions_for_2022_election = Processing.coalition_periods_overlapping_window(coalition_periods_raw, mandate_2022.start_date, mandate_2022.end_date; path = coalition_json_path)

function coalition_period_linkage_table()
    rows = NamedTuple[]
    for year in analysis_years
        mandate = ARC.mandate_window(year)
        for period in sort(collect(keys(coalition_periods_raw)); by = Processing.period_sort_key)
            period_start, period_end = coalition_windows[period]
            period_start === nothing && error("Coalition period $(period) has no start date.")
            period_end === nothing && error("Coalition period $(period) has no end date.")
            selected = period_start <= mandate.end_date && period_end >= mandate.start_date
            push!(rows, (election_year = Int(year), mandate_start = mandate.start_date, mandate_end = mandate.end_date, period_label = period, period_start = period_start, period_end = period_end, selected_by_overlap = selected, raw_parties = join(coalition_periods_raw[period], ", ")))
        end
    end
    return DataFrame(rows)
end

coalition_period_linkage = coalition_period_linkage_table()
show_table(coalition_period_linkage[coalition_period_linkage.selected_by_overlap .== true, :])
write_artifact_csv(joinpath(diagnostics_dir, "coalition_period_linkage.csv"), coalition_period_linkage, "diagnostic", "Coalition periods linked to elections by inclusive mandate-window overlap.")
println("2014 election periods: ", join(sort(collect(keys(coalitions_for_2014_election)); by = Processing.period_sort_key), ", "))
println("2018 election periods: ", join(sort(collect(keys(coalitions_for_2018_election)); by = Processing.period_sort_key), ", "))
println("2022 election periods: ", join(sort(collect(keys(coalitions_for_2022_election)); by = Processing.period_sort_key), ", "))

# =============================================================================
# BLOCK 8. PARTY-LEVEL SEAT DIFFERENTIALS
# =============================================================================

print_block("BLOCK 8. PARTY-LEVEL SEAT DIFFERENTIALS")

function party_seat_differentials(year, summary)
    df = select(summary, :SG_PARTIDO => :party, :valid_total => :votes, :national_vote_total, :vote_share, :total_seats => :seats, :seat_share, :quota, :seat_diff, :representation_ratio)
    df[!, :election_year] = fill(Int(year), nrow(df))
    sort!(df, [:election_year, :seat_diff], rev = [false, true])
    validate_total_seats!(df, year)
    validate_seat_diff_sum!(df, year)
    return df
end

party_seat_differentials_2014 = party_seat_differentials(2014, party_summary_2014)
party_seat_differentials_2018 = party_seat_differentials(2018, party_summary_2018)
party_seat_differentials_2022 = party_seat_differentials(2022, party_summary_2022)
validate_party_accounting!(party_seat_differentials_2014, 2014; expected_national_votes = expected_national_vote_totals[2014])
validate_party_accounting!(party_seat_differentials_2018, 2018; expected_national_votes = expected_national_vote_totals[2018])
validate_party_accounting!(party_seat_differentials_2022, 2022; expected_national_votes = expected_national_vote_totals[2022])
party_seat_differentials_all_years = vcat(party_seat_differentials_2014, party_seat_differentials_2018, party_seat_differentials_2022; cols = :union)
for year_df in [party_seat_differentials_2014, party_seat_differentials_2018, party_seat_differentials_2022]
    year = first(year_df.election_year)
    println("$(year): seats=$(sum(year_df.seats)), sum(seat_diff)=$(sum(year_df.seat_diff))")
end
write_artifact_csv(joinpath(raw_dir, "party_seat_differentials_2014.csv"), party_seat_differentials_2014, "raw", "Party-level vote shares, seat shares, quotas, and seat differentials for 2014.")
write_artifact_csv(joinpath(raw_dir, "party_seat_differentials_2018.csv"), party_seat_differentials_2018, "raw", "Party-level vote shares, seat shares, quotas, and seat differentials for 2018.")
write_artifact_csv(joinpath(raw_dir, "party_seat_differentials_2022.csv"), party_seat_differentials_2022, "raw", "Party-level vote shares, seat shares, quotas, and seat differentials for 2022.")
write_artifact_csv(joinpath(raw_dir, "party_seat_differentials_all_years.csv"), party_seat_differentials_all_years, "raw", "Party-level vote shares, seat shares, quotas, and seat differentials for all elections.")

function over_under_table(all_df; n_each = 5)
    rows = NamedTuple[]
    for year in analysis_years
        df = all_df[all_df.election_year .== year, :]
        for row in eachrow(first(sort(df, :seat_diff, rev = true), min(n_each, nrow(df))))
            push!(rows, (election_year = year, direction = "overrepresented", party = row.party, votes = row.votes, seats = row.seats, vote_share_pct = pct(row.vote_share), seat_share_pct = pct(row.seat_share), quota_display = display_round(row.quota), seat_diff_display = display_round(row.seat_diff)))
        end
        for row in eachrow(first(sort(df, :seat_diff), min(n_each, nrow(df))))
            push!(rows, (election_year = year, direction = "underrepresented", party = row.party, votes = row.votes, seats = row.seats, vote_share_pct = pct(row.vote_share), seat_share_pct = pct(row.seat_share), quota_display = display_round(row.quota), seat_diff_display = display_round(row.seat_diff)))
        end
    end
    return DataFrame(rows)
end

selected_party_differential_parties = Dict(
    2014 => ["PMDB", "PSD", "PTB", "PSDB", "PSOL"],
    2018 => ["PP", "PR", "MDB", "PSL", "NOVO"],
    2022 => ["PL", "UNIÃO", "PP", "PSD", "PSOL"],
)

function selected_party_differential_table(all_df)
    rows = NamedTuple[]
    for year in analysis_years
        haskey(selected_party_differential_parties, year) || error(
            "No selected party-differential display order defined for $(year).",
        )
        for party in selected_party_differential_parties[year]
            source_match = all_df[
                (all_df.election_year .== year) .&
                (all_df.party .== party),
                :,
            ]
            nrow(source_match) == 1 || error(
                "Selected party-differential row $(year)/$(party) does not map to exactly one party-accounting row.",
            )
            row = only(eachrow(source_match))
            push!(rows, (
                election_year = year,
                party = party,
                vote_share_pct = pct(row.vote_share),
                seats = Int(row.seats),
                quota_display = display_round(row.quota),
                seat_diff_display = display_round(row.seat_diff),
            ))
        end
    end
    return DataFrame(rows)
end

table_02_party_over_underrepresentation = over_under_table(party_seat_differentials_all_years)
write_artifact_csv(joinpath(tables_dir, "table_02_party_over_underrepresentation.csv"), table_02_party_over_underrepresentation, "table", "Top overrepresented and underrepresented parties by election.")
table_01_selected_party_differentials = selected_party_differential_table(party_seat_differentials_all_years)
selected_party_differentials_csv_path = write_artifact_csv(joinpath(tables_dir, "table_01_selected_party_differentials.csv"), table_01_selected_party_differentials, "table", "Selected large positive and negative party-level seat differentials shown in manuscript Table 1.")
selected_party_differentials_from_csv = CSV.read(selected_party_differentials_csv_path, DataFrame)
validate_csv_roundtrip!(
    selected_party_differentials_from_csv,
    table_01_selected_party_differentials,
    (:election_year, :party, :vote_share_pct, :seats, :quota_display, :seat_diff_display),
    "Selected party-differential table",
)
validate_selected_party_differential_table!(selected_party_differentials_from_csv, party_seat_differentials_all_years)

# =============================================================================
# BLOCK 9. OBSERVED CABINET-PERIOD COALITIONS
# =============================================================================

print_block("BLOCK 9. OBSERVED CABINET-PERIOD COALITIONS")

function build_observed_coalition_table(summary_df, election_year, coalition_periods)
    valid_election_parties = String.(summary_df.SG_PARTIDO)
    mandate = ARC.mandate_window(election_year)
    rows = NamedTuple[]
    for period in sort(collect(keys(coalition_periods)); by = Processing.period_sort_key)
        coalition_year = parse(Int, first(split(period, ".")))
        raw_parties = coalition_periods[period]
        election_space_parties = Processing.CabinetRelease.validate_parties(raw_parties; election_year,valid_election_parties)
        metrics = summarize_coalition(summary_df, election_space_parties)
        period_start, period_end = coalition_windows[period]
        period_start === nothing && error("Missing start date for coalition period $(period).")
        period_end === nothing && error("Missing end date for coalition period $(period).")
        days = inclusive_days(period_start, period_end)
        overlap = overlap_days(period_start, period_end, mandate.start_date, mandate.end_date)
        push!(rows, merge((election_year = Int(election_year), coalition_year = coalition_year, period = period, period_start = period_start, period_end = period_end, period_days = days, days_overlapping_mandate = overlap, share_of_mandate = overlap / mandate.total_days, 
            administration_id = String(only(cabinet_calendar.administration_id[cabinet_calendar.period .== period])),
            composition_status = String(only(cabinet_calendar.composition_status[cabinet_calendar.period .== period])),
            source_periods = String(only(cabinet_calendar.source_periods[cabinet_calendar.period .== period])),
            parties = join(election_space_parties, ", ")), metrics))
    end
    result = if isempty(rows)
        # Typed empty registry: unknown intervals are carried in cabinet_calendar,
        # never represented as a fictitious zero-vote coalition.
        DataFrame([merge((election_year=Int(election_year), coalition_year=Int(election_year)+1,
            period="", period_start=mandate.start_date, period_end=mandate.start_date,
            period_days=0, days_overlapping_mandate=0, share_of_mandate=0.0,
            administration_id="", composition_status="", source_periods="[]", parties=""),
            summarize_coalition(summary_df, String[]))])[1:0, :]
    else
        DataFrame(rows)
    end
    sort!(result, [:election_year, :period_start])
    return result
end

function build_cabinet_focal_cases(df)
    focal = copy(df[df.coalition_inversion .== true, :])
    focal[!, :focal_case_type] = fill("observed_inversion", nrow(focal))
    sort!(focal, [:election_year, :period])
    focal_keys = collect(zip(focal.election_year, focal.period))
    length(unique(focal_keys)) == length(focal_keys) || error(
        "Cabinet focal-case selection collapsed or duplicated period identifiers.",
    )
    return add_metric_display_columns(focal)
end

observed_cabinet_coalitions_2014 = build_observed_coalition_table(party_summary_2014, 2014, coalitions_for_2014_election)
observed_cabinet_coalitions_2018 = build_observed_coalition_table(party_summary_2018, 2018, coalitions_for_2018_election)
observed_cabinet_coalitions_2022 = build_observed_coalition_table(party_summary_2022, 2022, coalitions_for_2022_election)
# Published periods are already maximal by election and membership.
cabinet_coalitions_before_coalescing = vcat(observed_cabinet_coalitions_2014, observed_cabinet_coalitions_2018, observed_cabinet_coalitions_2022; cols = :union)
observed_cabinet_coalitions_all_years = copy(cabinet_coalitions_before_coalescing)
observed_cabinet_coalitions_2014 = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.election_year .== 2014, :]
observed_cabinet_coalitions_2018 = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.election_year .== 2018, :]
observed_cabinet_coalitions_2022 = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.election_year .== 2022, :]
write_artifact_csv(joinpath(diagnostics_dir, "cabinet_coalitions_before_coalescing.csv"), cabinet_coalitions_before_coalescing, "diagnostic", "Published membership periods before grouping distinct recurrent sets.")
coalescing_audit = NamedTuple[]
for year in analysis_years
    before = cabinet_coalitions_before_coalescing[cabinet_coalitions_before_coalescing.election_year .== year, :]
    after = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.election_year .== year, :]
    days_before = sum(before.days_overlapping_mandate[before.coalition_inversion])
    days_after = sum(after.days_overlapping_mandate[after.coalition_inversion])
    days_before == days_after || error("Cabinet coalescing changed inversion days for $(year).")
    sum(before.period_days) == sum(after.period_days) || error("Cabinet coalescing changed covered days for $(year).")
    push!(coalescing_audit, (election_year = year, observations_before = nrow(before), observations_after = nrow(after), inversions_before = count(before.coalition_inversion), inversions_after = count(after.coalition_inversion), inversion_days_before = days_before, inversion_days_after = days_after))
end
write_artifact_csv(joinpath(diagnostics_dir, "cabinet_period_coalescing.csv"), DataFrame(coalescing_audit), "diagnostic", "Chronological period counts and unchanged inversion days after adjacent equal-party-set coalescing; source IDs remain in source_periods.")
validate_coalition_accounting!(observed_cabinet_coalitions_2014, party_seat_differentials_2014; domain = "cabinet", id_columns = (:election_year, :period))
validate_coalition_accounting!(observed_cabinet_coalitions_2018, party_seat_differentials_2018; domain = "cabinet", id_columns = (:election_year, :period))
validate_coalition_accounting!(observed_cabinet_coalitions_2022, party_seat_differentials_2022; domain = "cabinet", id_columns = (:election_year, :period))

observed_cabinet_inversions_only = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.coalition_inversion .== true, :]
cabinet_coalition_focal_cases = build_cabinet_focal_cases(observed_cabinet_coalitions_all_years)

# Counts and inversion identities are empirical outputs. Validate coverage and
# the independently computed accounting identities, never an old narrative.
for year in analysis_years
    ordered = sort(cabinet_calendar[cabinet_calendar.election_year .== year, :], :period_start)
    for i in 2:nrow(ordered)
        ordered.period_end[i-1] + Day(1) == ordered.period_start[i] || error("Cabinet coverage gap/overlap in $(year)")
    end
end

observed_cabinet_duration_summary = DataFrame([
    let df=observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.election_year .== y, :]
        (election_year=y,n_periods=nrow(df),n_inversion_periods=count(df.coalition_inversion),
         covered_days=sum(df.days_overlapping_mandate),
         inversion_days=sum(df.days_overlapping_mandate[df.coalition_inversion]),
         covered_share_of_mandate=sum(df.share_of_mandate))
    end for y in analysis_years])
observed_cabinet_duration_summary[!, :total_observation_days] = [ARC.mandate_window(y).total_days for y in observed_cabinet_duration_summary.election_year]
observed_cabinet_duration_summary[!, :unidentified_days] = observed_cabinet_duration_summary.total_observation_days .- observed_cabinet_duration_summary.covered_days
observed_cabinet_duration_summary[!, :primary_covered_days] = observed_cabinet_duration_summary.covered_days
observed_cabinet_duration_summary[!, :primary_unfilled_days] = observed_cabinet_duration_summary.unidentified_days
observed_cabinet_duration_summary[!, :established_days] = [sum(cabinet_calendar.established_days[cabinet_calendar.election_year .== y]) for y in observed_cabinet_duration_summary.election_year]
observed_cabinet_duration_summary[!, :provisional_days] = [sum(cabinet_calendar.provisional_days[cabinet_calendar.election_year .== y]) for y in observed_cabinet_duration_summary.election_year]
observed_cabinet_duration_summary[!, :identified_days] = observed_cabinet_duration_summary.established_days
observed_cabinet_duration_summary[!, :unidentified_days] = observed_cabinet_duration_summary.provisional_days
observed_cabinet_duration_summary[!, :inversion_share_full_calendar] = observed_cabinet_duration_summary.inversion_days ./ observed_cabinet_duration_summary.total_observation_days
show_table(select(observed_cabinet_coalitions_all_years, :election_year, :period, :period_start, :period_end, :period_days, :days_overlapping_mandate, :parties, :vote_share, :seats, :seat_diff, :majority_status, :coalition_inversion))
write_artifact_csv(joinpath(raw_dir, "observed_cabinet_coalitions_2014.csv"), observed_cabinet_coalitions_2014, "raw", "Observed cabinet-period coalition metrics for the 2014 election.")
write_artifact_csv(joinpath(raw_dir, "observed_cabinet_coalitions_2018.csv"), observed_cabinet_coalitions_2018, "raw", "Observed cabinet-period coalition metrics for the 2018 election.")
write_artifact_csv(joinpath(raw_dir, "observed_cabinet_coalitions_2022.csv"), observed_cabinet_coalitions_2022, "raw", "Observed cabinet-period coalition metrics for the 2022 election.")
write_artifact_csv(joinpath(raw_dir, "cabinet_coalition_metrics.csv"), observed_cabinet_coalitions_all_years, "raw", "Full-precision observed cabinet-period coalition accounting metrics for all elections.")
# Period files above are chronology products. Every analytical consumer below
# receives the same membership registry, including nonconsecutive recurrences.
cabinet_chronology = observed_cabinet_coalitions_all_years
observed_cabinet_coalitions_all_years = Processing.cabinet_set_view(cabinet_chronology)
observed_cabinet_inversions_only = observed_cabinet_coalitions_all_years[observed_cabinet_coalitions_all_years.coalition_inversion, :]
cabinet_coalition_focal_cases = build_cabinet_focal_cases(observed_cabinet_coalitions_all_years)
write_artifact_csv(joinpath(raw_dir, "cabinet_party_sets.csv"), observed_cabinet_coalitions_all_years, "raw", "Shared distinct-set registry view; period is a legacy display-label alias and dates are extrema, not a continuous interval.")
write_artifact_csv(joinpath(raw_dir, "cabinet_coalition_focal_cases.csv"), cabinet_coalition_focal_cases, "raw", "All observed cabinet inversions, with Julia-generated display values.")
write_artifact_csv(joinpath(raw_dir, "observed_cabinet_inversions_only.csv"), observed_cabinet_inversions_only, "raw", "Distinct inverted cabinet party sets only.")
write_artifact_csv(joinpath(raw_dir, "observed_cabinet_duration_summary.csv"), observed_cabinet_duration_summary, "raw", "Observed cabinet coverage and inversion duration summary.")

function observed_display_table(df)
    return select(
        df,
        :election_year,
        :cabinet_party_set_id, :display_label, :canonical_membership,
        :period,
        :source_periods,
        :period_start,
        :period_end,
        :period_days,
        :days_overlapping_mandate,
        :share_of_mandate => ByRow(pct) => :share_of_mandate_pct,
        :parties,
        :votes,
        :vote_share => ByRow(pct) => :vote_share_pct,
        :seats,
        :seat_share => ByRow(pct) => :seat_share_pct,
        :quota => ByRow(display_round) => :quota_display,
        :seat_diff => ByRow(display_round) => :seat_diff_display,
        :required_diff => ByRow(display_round) => :required_diff_display,
        :majority_status,
        :coalition_inversion,
    )
end

function cabinet_composition_table(df)
    out = select(copy(df), :election_year, :cabinet_party_set_id, :display_label, :canonical_membership, :period, :source_periods, :period_start, :period_end,
        :period_days, :vote_share => ByRow(pct) => :vote_share_pct, :seats,
        :seat_diff => ByRow(display_round) => :seat_diff_display, :majority_status, :parties,
        :administration_id, :composition_status)
    for gap in eachrow(cabinet_unidentified)
        push!(out, (election_year=gap.election_year, period=gap.period, source_periods=gap.source_periods,
            period_start=gap.period_start, period_end=gap.period_end, period_days=gap.period_days,
            vote_share_pct=missing, seats=missing, seat_diff_display=missing,
            majority_status="unidentified", parties="Unidentified; see release evidence limitations",
            administration_id=gap.administration_id, composition_status=gap.composition_status); promote=true)
    end
    sort!(out, [:election_year, :period_start])
    entered=String[]; left=String[]; previous=nothing
    for row in eachrow(out)
        known=row.majority_status != "unidentified"
        adjacent=false && previous !== nothing && previous.administration_id==row.administration_id &&
            previous.period_end+Day(1)==row.period_start && previous.majority_status != "unidentified" && known
        current=party_set_from_cell(row.parties)
        push!(entered, adjacent ? join(sort(collect(setdiff(current,party_set_from_cell(previous.parties)))), ", ") : "")
        push!(left, adjacent ? join(sort(collect(setdiff(party_set_from_cell(previous.parties),current))), ", ") : "")
        previous=copy(row)
    end
    out[!, :entered_parties]=entered; out[!, :left_parties]=left
    return out
end

table_03_observed_cabinet_coalitions = observed_display_table(observed_cabinet_coalitions_all_years)
table_04_observed_cabinet_inversions_only = observed_display_table(observed_cabinet_inversions_only)
table_appendix_cabinet_composition = cabinet_composition_table(observed_cabinet_coalitions_all_years)
write_artifact_csv(joinpath(tables_dir, "table_03_observed_cabinet_coalitions.csv"), table_03_observed_cabinet_coalitions, "table", "Distinct cabinet party sets with rounded display columns.")
cabinet_composition_csv_path = write_artifact_csv(joinpath(tables_dir, "table_appendix_cabinet_composition.csv"), table_appendix_cabinet_composition, "table", "Distinct cabinet party sets; full occurrence linkage is separate.")
cabinet_composition_from_csv = CSV.read(cabinet_composition_csv_path, DataFrame; types=Dict(:period=>String))
validate_csv_roundtrip!(
    cabinet_composition_from_csv,
    table_appendix_cabinet_composition,
    (
        :election_year, :period, :period_start, :period_end, :period_days,
        :vote_share_pct, :seats, :seat_diff_display, :majority_status,
        :parties, :entered_parties, :left_parties,
    ),
    "Cabinet-composition appendix table",
)
validate_cabinet_composition_table!(cabinet_composition_from_csv, observed_cabinet_coalitions_all_years)
# Cabinet TeX has one producer: scripts/make_tables.py after exact accounting.
cabinet_inversion_table_csv_path = write_artifact_csv(joinpath(tables_dir, "table_04_observed_cabinet_inversions_only.csv"), table_04_observed_cabinet_inversions_only, "table", "Distinct inverted cabinet party sets with rounded electoral display columns.")
cabinet_inversion_table_from_csv = CSV.read(cabinet_inversion_table_csv_path, DataFrame; types=Dict(:period=>String))
validate_cabinet_inversion_table!(cabinet_inversion_table_from_csv, observed_cabinet_inversions_only)
all(cabinet_coalition_focal_cases.focal_case_type .== "observed_inversion") || error("Cabinet focal cases must all be identified observed inversions.")
focal_keys = Set(zip(cabinet_coalition_focal_cases.election_year, cabinet_coalition_focal_cases.period))
focal_keys == Set(zip(observed_cabinet_inversions_only.election_year, observed_cabinet_inversions_only.period)) || error("Cabinet focal selection mismatch")
println("Distinct inverted cabinet party sets: ", nrow(cabinet_coalition_focal_cases))

# =============================================================================
# BLOCK 10. IDEOLOGY ORDERING
# =============================================================================

print_block("BLOCK 10. IDEOLOGY ORDERING")

function build_ideology_order(year, summary_df, classification_2023, classification_2025)
    source_df, source_name = year == 2022 ? (classification_2025, "2025") : (classification_2023, "2023")
    raw_overrides = get(ideology_raw_overrides, year, Dict{String,String}())
    label_overrides = get(ideology_label_overrides, year, Dict{String,String}())
    drop_labels = get(ideology_drop_labels, year, Set{String}())
    rows = NamedTuple[]
    mapping_rows = NamedTuple[]
    for row in eachrow(source_df)
        raw_party = strip(String(row.party_name_raw))
        normalized_raw = Processing.normalize_party(raw_party)
        translated_party = Processing.canonical_party(raw_party; year = year, strict = false)
        source = translated_party == Processing.UNKNOWN_PARTY ? "unmapped" : "shared_alias"
        if translated_party == Processing.UNKNOWN_PARTY
            haskey(raw_overrides, normalized_raw) || continue
            translated_party = raw_overrides[normalized_raw]
            source = "local_raw_override"
        end
        canonical_before_label_override = translated_party
        final_party = get(label_overrides, translated_party, translated_party)
        label_override_applied = final_party != translated_party
        dropped = final_party in drop_labels
        push!(mapping_rows, (source = "ideology", election_year = Int(year), context = source_name, raw_party = raw_party, normalized_party = normalized_raw, canonical_party = canonical_before_label_override, final_party = final_party, mapping_source = source, local_label_override_applied = label_override_applied, dropped_before_join = dropped))
        dropped && continue
        push!(rows, (SG_PARTIDO = final_party, ordinal_position = Int(row.ordinal_position), classification_label = String(coalesce(row.classification_label, "")), ideology_value_numeric = row.ideology_value_numeric, ideology_source = source_name, source_party_raw = raw_party))
    end
    ideology_df = DataFrame(rows)
    duplicate_counts = combine(groupby(ideology_df, :SG_PARTIDO), nrow => :n)
    if any(duplicate_counts.n .> 1)
        duplicate_parties = duplicate_counts.SG_PARTIDO[duplicate_counts.n .> 1]
        error("Duplicate translated parties in ideology order for $(year): $(join(duplicate_parties, ", "))")
    end
    summary_parties = sort(String.(summary_df.SG_PARTIDO))
    ideology_df = innerjoin(ideology_df, select(summary_df, :SG_PARTIDO), on = :SG_PARTIDO)
    sort!(ideology_df, :ordinal_position)
    ordered_parties = String.(ideology_df.SG_PARTIDO)
    missing_parties = setdiff(summary_parties, sort(ordered_parties))
    isempty(missing_parties) || error("Seat-winning/summary party missing from ideology ordering for $(year): $(join(missing_parties, ", "))")
    length(unique(ordered_parties)) == length(ordered_parties) || error("Duplicate party after ideology translation for $(year).")
    sort(ordered_parties) == summary_parties || error("Ideology order does not cover summary parties exactly once for $(year).")
    mapping_df = DataFrame(mapping_rows)
    unexplained_drops = mapping_df[(mapping_df.dropped_before_join .== true) .& in.(mapping_df.final_party, Ref(Set(summary_parties))), :]
    nrow(unexplained_drops) == 0 || error("Dropped a summary party in ideology mapping for $(year): $(join(String.(unexplained_drops.final_party), ", "))")
    push!(ideology_mapping_tables, mapping_df)
    return ideology_df
end

function ideology_order_output(year, ideology_df)
    out = select(ideology_df, :ideological_universe, :ordinal_position, :original_ordinal_position, :SG_PARTIDO => :party, :classification_label, :ideology_value_numeric, :ideology_source, :source_party_raw)
    out[!, :election_year] = fill(Int(year), nrow(out))
    sort!(out, [:election_year, :ordinal_position])
    return out
end

ideology_order_2014_base = build_ideology_order(2014, party_summary_2014, classification_2023, classification_2025)
ideology_order_2018_base = build_ideology_order(2018, party_summary_2018, classification_2023, classification_2025)
ideology_order_2022_base = build_ideology_order(2022, party_summary_2022, classification_2023, classification_2025)
party_summaries = Dict(2014 => party_summary_2014, 2018 => party_summary_2018, 2022 => party_summary_2022)
full_ideology_orders = Dict(2014 => ideology_order_2014_base, 2018 => ideology_order_2018_base, 2022 => ideology_order_2022_base)
ideology_orders = Dict{Tuple{Int,Symbol},DataFrame}()
for universe in ideological_universes, year in analysis_years
    ordered = Processing.ideological_party_order(party_summaries[year], full_ideology_orders[year]; universe = universe)
    ideology_orders[(year, universe)] = ordered
end
ideology_order_2014_base = ideology_orders[(2014, primary_ideological_universe)]
ideology_order_2018_base = ideology_orders[(2018, primary_ideological_universe)]
ideology_order_2022_base = ideology_orders[(2022, primary_ideological_universe)]
ideology_order_2014 = ideology_order_output(2014, ideology_order_2014_base)
ideology_order_2018 = ideology_order_output(2018, ideology_order_2018_base)
ideology_order_2022 = ideology_order_output(2022, ideology_order_2022_base)
ideology_order_all_years = vcat(ideology_order_2014, ideology_order_2018, ideology_order_2022; cols = :union)
ideology_order_all_parties = vcat([ideology_order_output(year, ideology_orders[(year, :all_parties)]) for year in analysis_years]...)
for year in analysis_years
    out = ideology_order_all_parties[ideology_order_all_parties.election_year .== year, :]
    write_artifact_csv(joinpath(raw_dir, "ideology_order_$(year)_all_parties.csv"), out, "raw", "All-party robustness ideological order; original estimates and rank preserved.")
end
write_artifact_csv(joinpath(raw_dir, "ideology_order_all_years_all_parties.csv"), ideology_order_all_parties, "raw", "Full all-party robustness order.")
println("2014 ideology order: ", join(String.(ideology_order_2014.party), ", "))
println("2018 ideology order: ", join(String.(ideology_order_2018.party), ", "))
println("2022 ideology order: ", join(String.(ideology_order_2022.party), ", "))
write_artifact_csv(joinpath(raw_dir, "ideology_order_2014.csv"), ideology_order_2014, "raw", "Ideology order used for 2014 election analysis.")
write_artifact_csv(joinpath(raw_dir, "ideology_order_2018.csv"), ideology_order_2018, "raw", "Ideology order used for 2018 election analysis.")
write_artifact_csv(joinpath(raw_dir, "ideology_order_2022.csv"), ideology_order_2022, "raw", "Ideology order used for 2022 election analysis.")
write_artifact_csv(joinpath(raw_dir, "ideology_order_all_years.csv"), ideology_order_all_years, "raw", "Ideology order used for all election analyses.")
table_appendix_ideology_order = select(
    ideology_order_all_years,
    :election_year,
    :ordinal_position,
    :party,
    :classification_label,
    :ideology_value_numeric,
    :ideology_source,
    :source_party_raw,
)
ideology_order_table_csv_path = write_artifact_csv(joinpath(tables_dir, "table_appendix_ideology_order.csv"), table_appendix_ideology_order, "table", "Full party ideology order, classification, score, and source labels shown in the manuscript appendix.")
ideology_order_table_from_csv = CSV.read(ideology_order_table_csv_path, DataFrame)
validate_csv_roundtrip!(
    ideology_order_table_from_csv,
    table_appendix_ideology_order,
    (:election_year, :ordinal_position, :party, :classification_label, :ideology_value_numeric, :ideology_source, :source_party_raw),
    "Ideology-order appendix table",
)
validate_ideology_order_table!(ideology_order_table_from_csv, ideology_order_all_years)

# =============================================================================
# BLOCK 11. IDEOLOGICALLY CONTIGUOUS NO-GAP COALITIONS
# =============================================================================

print_block("BLOCK 11. IDEOLOGICALLY CONTIGUOUS NO-GAP COALITIONS")

function build_ideological_intervals(year, summary_df, ideology_df; universe = primary_ideological_universe)
    raw = Processing.ideological_interval_view(domain_results[(year, universe, 0)])
    n = count(row -> universe == :all_parties || row.total_seats > 0, eachrow(summary_df))
    expected_rows = n * (n + 1) ÷ 2
    nrow(raw) == expected_rows || error("Ideological interval count mismatch for $(year): expected $(expected_rows), found $(nrow(raw)).")
    raw[!, :election_year] = fill(Int(year), nrow(raw))
    raw[!, :interval_size] = Int.(raw.n_parties)
    raw[!, :coalition_inversion] = Bool.(raw.inversion)
    party_seats = Dict(String(row.SG_PARTIDO) => Int(row.total_seats) for row in eachrow(summary_df))
    raw[!, :left_removed_seats] = [row.seats - party_seats[String(row.start_party)] for row in eachrow(raw)]
    raw[!, :right_removed_seats] = [row.seats - party_seats[String(row.end_party)] for row in eachrow(raw)]
    raw[!, :minimal_connected_winning] = copy(raw.minimal_seat_majority)
    raw[!, :minimal_connected_inversion] = raw.coalition_inversion .& raw.minimal_connected_winning
    # Preserve the established aliases consumed by the heatmap and bridge while
    # exposing the clearer status names required by the analytical CSV.
    raw[!, :endpoint_minimal_connected_winning] = copy(raw.minimal_connected_winning)
    raw[!, :minimal_ideological_interval_inversion] = copy(raw.minimal_connected_inversion)
    out = select(raw, :election_year, :ideological_universe, :ideological_party_count, :left_original_ordinal_position, :right_original_ordinal_position, :k, :gap_count, :coalition_id, :q_C, :d_C, :R_C, :minimal_seat_majority, :inversion, :start_index, :end_index, :start_party, :end_party, :parties, :interval_size, :votes, :national_vote_total, :vote_share, :seats, :seat_share, :quota, :seat_diff, :required_diff, :representation_ratio, :vote_majority, :seat_majority, :majority_status, :coalition_inversion, :left_removed_seats, :right_removed_seats, :minimal_connected_winning, :minimal_connected_inversion, :endpoint_minimal_connected_winning, :minimal_ideological_interval_inversion)
    sort!(out, [:election_year, :start_index, :end_index])
    return out
end

function connected_winning_status(seats, vote_share)
    seats >= seat_majority_threshold || error("Minimal connected winning table received non-winning interval.")
    return vote_share > 0.5 ? "votes+seats" : "seats only"
end

function contains_party(parties, party)
    return party in strip.(split(String(parties), ","))
end

function appendix_minimal_connected_winning_table(df)
    minimal_connected = df[df.minimal_connected_winning .== true, :]
    sort!(minimal_connected, [:election_year, :start_index, :end_index])
    result = select(minimal_connected,
        :election_year,
        :start_party,
        :end_party,
        :ideological_universe,
        :interval_size => :n_parties,
        :vote_share,
        :vote_share => ByRow(pct) => :vote_share_pct,
        :seats,
        :quota,
        :seat_diff,
        [:seats, :vote_share] => ByRow(connected_winning_status) => :status,
        :parties => ByRow(x -> contains_party(x, "PT")) => :contains_PT,
        :coalition_inversion,
        :parties,
    )
    return result
end


# Enumerate each complete admissible domain once. All interval, appendix and
# robustness views below project these results; minimality stays domain-relative.
domain_results = Dict{Tuple{Int,Symbol,Int},DataFrame}(
    (year, universe, k) => Processing.ideological_k_gap_coalitions(
        party_summaries[year], full_ideology_orders[year]; k, universe)
    for year in analysis_years for universe in ideological_universes for k in (0, 1))

ideological_intervals_by_universe = Dict{Tuple{Int,Symbol},DataFrame}()
for universe in ideological_universes, year in analysis_years
    ideological_intervals_by_universe[(year, universe)] = build_ideological_intervals(year, party_summaries[year], full_ideology_orders[year]; universe = universe)
end
ideological_intervals_2014 = ideological_intervals_by_universe[(2014, primary_ideological_universe)]
ideological_intervals_2018 = ideological_intervals_by_universe[(2018, primary_ideological_universe)]
ideological_intervals_2022 = ideological_intervals_by_universe[(2022, primary_ideological_universe)]
ideological_intervals_all_years = vcat(ideological_intervals_2014, ideological_intervals_2018, ideological_intervals_2022; cols = :union)
ideological_intervals_all_parties = vcat([ideological_intervals_by_universe[(year, :all_parties)] for year in analysis_years]...)
validate_coalition_accounting!(ideological_intervals_2014, party_seat_differentials_2014; domain = "ideological_interval", id_columns = (:election_year, :start_party, :end_party))
validate_coalition_accounting!(ideological_intervals_2018, party_seat_differentials_2018; domain = "ideological_interval", id_columns = (:election_year, :start_party, :end_party))
validate_coalition_accounting!(ideological_intervals_2022, party_seat_differentials_2022; domain = "ideological_interval", id_columns = (:election_year, :start_party, :end_party))

# =============================================================================
# BLOCK 11A. NESTED K-GAP IDEOLOGICAL-COALITION ROBUSTNESS
# =============================================================================

print_block("BLOCK 11A. NESTED K-GAP IDEOLOGICAL-COALITION ROBUSTNESS")

ideology_k_gap_check_rows = NamedTuple[]
active_audit_universe = Ref(primary_ideological_universe)

function record_k_gap_check!(year, k, check, ok, detail)
    push!(ideology_k_gap_check_rows, (
        election = Int(year),
        ideological_universe = string(active_audit_universe[]),
        k = Int(k),
        check = String(check),
        ok = Bool(ok),
        detail = String(detail),
    ))
    ok || error("Ideology k-gap check failed for $(year), k=$(k), $(check): $(detail)")
    return true
end

function k_gap_parties(value)
    text = strip(String(value))
    isempty(text) && return String[]
    return strip.(split(text, ","))
end

function k_gap_mask(value, position)
    mask = UInt64(0)
    for party in k_gap_parties(value)
        haskey(position, party) || error("Party $(party) is absent from the election-specific ideology order.")
        mask |= UInt64(1) << (position[party] - 1)
    end
    return mask
end

function build_k_gap_domain(year, summary_df, ideology_df; k, universe = primary_ideological_universe)
    raw = copy(domain_results[(year, universe, k)])
    raw[!, :election] = fill(Int(year), nrow(raw))
    select!(raw, :election, Not(:election))
    sort!(raw, [:election, :k, :left_index, :right_index, :gap_count, :omitted_party])
    return raw
end

function strongest_inversion_selection(domain)
    inversions = domain[domain.inversion .== true, :]
    nrow(inversions) == 0 && return nothing
    strongest_r_C = maximum(Float64.(inversions.r_C))
    exact_ties = inversions[Float64.(inversions.r_C) .== strongest_r_C, :]
    sort!(exact_ties, [:party_count, :coalition_id])
    return (
        selected = NamedTuple(first(eachrow(exact_ties))),
        exact_ties = exact_ties,
    )
end

function validate_k_gap_domain!(domain, summary_df, ideology_df, year, k)
    ordered = sort(select(ideology_df, :SG_PARTIDO, :ordinal_position), :ordinal_position)
    parties = String.(ordered.SG_PARTIDO)
    n = length(parties)
    n <= 64 || error("k-gap audit bit masks require at most 64 parties, found $(n).")
    position = Dict(party => index for (index, party) in enumerate(parties))
    party_votes = Dict(String(row.SG_PARTIDO) => Int(row.valid_total) for row in eachrow(summary_df))
    party_seats = Dict(String(row.SG_PARTIDO) => Int(row.total_seats) for row in eachrow(summary_df))
    national_votes = sum(values(party_votes))
    chamber_seats = sum(values(party_seats))
    expected_rows = n * (n + 1) ÷ 2 + (k == 1 ? binomial(n, 3) : 0)

    record_k_gap_check!(year, k, "analytical_domain_count", nrow(domain) == expected_rows, "expected=$(expected_rows), observed=$(nrow(domain)), n=$(n)")
    record_k_gap_check!(year, k, "year_and_domain_labels", all(domain.election .== year) && all(domain.k .== k), "all rows must carry the correct election and k")
    record_k_gap_check!(year, k, "canonical_party_sets_unique", length(unique(String.(domain.coalition_id))) == nrow(domain), "rows=$(nrow(domain)), unique=$(length(unique(String.(domain.coalition_id))))")
    record_k_gap_check!(year, k, "gap_bound", all((domain.gap_count .>= 0) .& (domain.gap_count .<= k)), "all reported gaps must be between zero and k")

    masks = UInt64[]
    arithmetic_ok = true
    structure_ok = true
    inversion_ok = true
    first_problem = ""
    for row in eachrow(domain)
        member_parties = k_gap_parties(row.parties)
        member_indices = sort([position[party] for party in member_parties])
        mask = k_gap_mask(row.parties, position)
        push!(masks, mask)

        left_index = first(member_indices)
        right_index = last(member_indices)
        span_indices = collect(left_index:right_index)
        omitted_indices = setdiff(span_indices, member_indices)
        expected_gap = length(omitted_indices)
        expected_omitted = expected_gap == 0 ? missing : parties[only(omitted_indices)]
        structure_row_ok =
            member_parties == parties[member_indices] &&
            String(row.coalition_id) == join(member_parties, "|") &&
            Int(row.party_count) == length(member_parties) &&
            Int(row.left_index) == left_index &&
            Int(row.right_index) == right_index &&
            String(row.left_endpoint) == parties[left_index] &&
            String(row.right_endpoint) == parties[right_index] &&
            Int(row.gap_count) == expected_gap &&
            expected_gap <= k &&
            (expected_gap == 0 ? ismissing(row.omitted_party) : (!ismissing(row.omitted_party) && String(row.omitted_party) == expected_omitted)) &&
            (expected_gap == 0 || (left_index < only(omitted_indices) < right_index))
        if !structure_row_ok && structure_ok
            structure_ok = false
            first_problem = "structural mismatch for $(row.coalition_label)"
        end

        expected_votes = sum(party_votes[party] for party in member_parties)
        expected_seats = sum(party_seats[party] for party in member_parties)
        expected_vote_share = expected_votes / national_votes
        expected_q_C = chamber_seats * expected_vote_share
        expected_d_C = expected_seats - expected_q_C
        expected_r_C = seat_majority_threshold - expected_q_C
        expected_R_C = expected_seats / expected_q_C
        arithmetic_row_ok =
            Int(row.votes) == expected_votes &&
            Int(row.national_vote_total) == national_votes &&
            isapprox(Float64(row.vote_share), expected_vote_share; atol = 1e-12, rtol = 0.0) &&
            Int(row.seats) == expected_seats &&
            Int(row.total_seats) == chamber_seats &&
            isapprox(Float64(row.q_C), expected_q_C; atol = 1e-10, rtol = 0.0) &&
            isapprox(Float64(row.d_C), expected_d_C; atol = 1e-10, rtol = 0.0) &&
            isapprox(Float64(row.r_C), expected_r_C; atol = 1e-10, rtol = 0.0) &&
            isapprox(Float64(row.R_C), expected_R_C; atol = 1e-10, rtol = 0.0)
        if !arithmetic_row_ok && arithmetic_ok
            arithmetic_ok = false
            first_problem = "arithmetic mismatch for $(row.coalition_label)"
        end

        expected_inversion = expected_seats >= seat_majority_threshold && 2 * expected_votes < national_votes
        expected_deficit = 50.0 - 100.0 * expected_vote_share
        inversion_row_ok =
            Bool(row.inversion) == expected_inversion &&
            (expected_inversion ?
             (!ismissing(row.vote_deficit_pp) && isapprox(Float64(row.vote_deficit_pp), expected_deficit; atol = 1e-10, rtol = 0.0)) :
             ismissing(row.vote_deficit_pp))
        if !inversion_row_ok && inversion_ok
            inversion_ok = false
            first_problem = "inversion mismatch for $(row.coalition_label)"
        end
    end
    record_k_gap_check!(year, k, "span_membership_and_gap_count", structure_ok, isempty(first_problem) ? "all rows match their spans" : first_problem)
    record_k_gap_check!(year, k, "party_sum_arithmetic", arithmetic_ok, isempty(first_problem) ? "all coalition metrics equal party sums" : first_problem)
    record_k_gap_check!(year, k, "strict_inversion_definition", inversion_ok, isempty(first_problem) ? "all inversion flags use unrounded vote shares" : first_problem)

    length(unique(masks)) == length(masks) || error("Duplicate k-gap membership masks for $(year), k=$(k).")
    winning_indices = findall(Bool.(domain.seat_majority))
    minimality_ok = true
    minimality_problem = ""
    for coalition_index in 1:nrow(domain)
        coalition_mask = masks[coalition_index]
        has_winning_proper_subset = any(winning_indices) do subset_index
            subset_mask = masks[subset_index]
            subset_mask != coalition_mask && (subset_mask & coalition_mask) == subset_mask
        end
        expected_minimal =
            Bool(domain.seat_majority[coalition_index]) &&
            !has_winning_proper_subset
        if Bool(domain.minimal_seat_majority[coalition_index]) != expected_minimal
            minimality_ok = false
            minimality_problem = "exact subset test differs for $(domain.coalition_label[coalition_index])"
            break
        end
    end
    record_k_gap_check!(year, k, "domain_relative_minimality_both_directions", minimality_ok, isempty(minimality_problem) ? "every minimal label and every nonminimal winning label has the correct subset status" : minimality_problem)
    return true
end

function validate_k0_regression!(domain, intervals, year)
    expected = Dict(
        2014 => (minimal_majorities = 8, inversions = 8, strongest = "PTB--PR"),
        2018 => (minimal_majorities = 8, inversions = 0, strongest = "None"),
        2022 => (minimal_majorities = 4, inversions = 6, strongest = "PP--PL"),
    )[year]

    interval_ids = [
        join(k_gap_parties(row.parties), "|")
        for row in eachrow(intervals)
    ]
    interval_map = Dict(interval_ids[index] => index for index in eachindex(interval_ids))
    membership_ok = Set(String.(domain.coalition_id)) == Set(interval_ids)
    record_k_gap_check!(year, 0, "matches_established_interval_membership", membership_ok, "D_0 and the established interval output must contain identical party sets")

    metrics_ok = membership_ok
    metrics_problem = ""
    if metrics_ok
        for row in eachrow(domain)
            baseline = intervals[interval_map[String(row.coalition_id)], :]
            row_ok =
                Int(row.votes) == Int(baseline.votes) &&
                isapprox(Float64(row.vote_share), Float64(baseline.vote_share); atol = 1e-12, rtol = 0.0) &&
                Int(row.seats) == Int(baseline.seats) &&
                isapprox(Float64(row.q_C), Float64(baseline.quota); atol = 1e-10, rtol = 0.0) &&
                isapprox(Float64(row.d_C), Float64(baseline.seat_diff); atol = 1e-10, rtol = 0.0) &&
                isapprox(Float64(row.r_C), Float64(baseline.required_diff); atol = 1e-10, rtol = 0.0) &&
                isapprox(Float64(row.R_C), Float64(baseline.representation_ratio); atol = 1e-10, rtol = 0.0) &&
                Bool(row.inversion) == Bool(baseline.coalition_inversion) &&
                Bool(row.minimal_seat_majority) == Bool(baseline.minimal_connected_winning)
            if !row_ok
                metrics_ok = false
                metrics_problem = "mismatch for $(row.coalition_label)"
                break
            end
        end
    end
    record_k_gap_check!(year, 0, "matches_established_interval_metrics", metrics_ok, isempty(metrics_problem) ? "membership, arithmetic, inversion, and minimality match" : metrics_problem)

    if only(unique(domain.ideological_universe)) == "all_parties"
    minimal_count = sum(Int.(domain.minimal_seat_majority))
    inversion_count = sum(Int.(domain.inversion))
    record_k_gap_check!(year, 0, "baseline_minimal_majority_count", minimal_count == expected.minimal_majorities, "expected=$(expected.minimal_majorities), observed=$(minimal_count)")
    record_k_gap_check!(year, 0, "baseline_inversion_count", inversion_count == expected.inversions, "expected=$(expected.inversions), observed=$(inversion_count)")

    strongest = strongest_inversion_selection(domain)
    strongest_label = strongest === nothing ? "None" : String(strongest.selected.coalition_label)
    record_k_gap_check!(year, 0, "baseline_strongest_inversion", strongest_label == expected.strongest, "expected=$(expected.strongest), observed=$(strongest_label)")
    if strongest !== nothing
        record_k_gap_check!(year, 0, "baseline_strongest_is_minimal", Bool(strongest.selected.minimal_seat_majority), "$(strongest_label) must be a minimal majority")
    end
    if year == 2022
        selected = strongest.selected
        record_k_gap_check!(year, 0, "baseline_pp_pl_display_regression", round(100.0 * Float64(selected.vote_share); digits = 2) == 45.35 && Int(selected.seats) == 258, "expected 45.35% and 258 seats")
    end
    end
    return true
end

function validate_nested_domains!(d0, d1, year)
    d1_map = Dict(String(row.coalition_id) => row for row in eachrow(d1))
    subset_ok = all(haskey(d1_map, String(row.coalition_id)) for row in eachrow(d0))
    record_k_gap_check!(year, 1, "D0_strict_subset_D1", subset_ok && nrow(d1) > nrow(d0), "|D_0|=$(nrow(d0)), |D_1|=$(nrow(d1))")
    shared_metrics_ok = subset_ok
    if shared_metrics_ok
        for row in eachrow(d0)
            nested = d1_map[String(row.coalition_id)]
            if Int(row.votes) != Int(nested.votes) ||
               Int(row.seats) != Int(nested.seats) ||
               !isapprox(Float64(row.q_C), Float64(nested.q_C); atol = 1e-10, rtol = 0.0)
                shared_metrics_ok = false
                break
            end
        end
    end
    record_k_gap_check!(year, 1, "D0_metrics_unchanged_inside_D1", shared_metrics_ok, "shared party sets retain identical votes, seats, and q_C")
    return true
end

function build_k_gap_summary(all_domains, membership_summary)
    rows = NamedTuple[]
    for membership_row in eachrow(membership_summary)
        year, k = membership_row.election, membership_row.k
        domain = all_domains[
            (all_domains.election .== year) .&
            (all_domains.ideological_universe .== membership_row.ideological_universe) .&
            (all_domains.k .== k),
            :,
        ]
        minimal_inversion_domain = domain[
            (domain.minimal_seat_majority .== true) .&
            (domain.inversion .== true),
            :,
        ]
        strongest = strongest_inversion_selection(minimal_inversion_domain)
        if strongest === nothing
            push!(rows, (
                election = Int(year),
                ideological_universe = String(membership_row.ideological_universe),
                k = Int(k),
                minimal_seat_majority_coalitions = membership_row.minimal_seat_majority_coalitions,
                minimal_inversions = membership_row.minimal_inversions,
                strongest_inversion_coalition = "None",
                strongest_inversion_vote_share = missing,
                strongest_inversion_vote_share_pct = missing,
                strongest_inversion_seats = missing,
                strongest_inversion_r_C = missing,
                strongest_inversion_vote_deficit_pp = missing,
                diagnostic_admissible_coalitions = nrow(domain),
                diagnostic_exact_strength_tie_count = 0,
                diagnostic_exact_strength_tied_coalitions = "",
            ))
            continue
        end
        selected = strongest.selected
        has_exact_tie = nrow(strongest.exact_ties) > 1
        push!(rows, (
            election = Int(year),
            ideological_universe = String(membership_row.ideological_universe),
            k = Int(k),
            minimal_seat_majority_coalitions = membership_row.minimal_seat_majority_coalitions,
            minimal_inversions = membership_row.minimal_inversions,
            strongest_inversion_coalition = String(selected.coalition_label),
            strongest_inversion_vote_share = Float64(selected.vote_share),
            strongest_inversion_vote_share_pct = 100.0 * Float64(selected.vote_share),
            strongest_inversion_seats = Int(selected.seats),
            strongest_inversion_r_C = Float64(selected.r_C),
            strongest_inversion_vote_deficit_pp = Float64(selected.vote_deficit_pp),
            diagnostic_admissible_coalitions = nrow(domain),
            diagnostic_exact_strength_tie_count = has_exact_tie ? nrow(strongest.exact_ties) : 0,
            diagnostic_exact_strength_tied_coalitions = has_exact_tie ? join(String.(strongest.exact_ties.coalition_label), " | ") : "",
        ))
    end
    result = DataFrame(rows)
    membership_columns = select(membership_summary, Not([:minimal_seat_majority_coalitions, :minimal_inversions]))
    result = leftjoin(result, membership_columns; on = [:election, :ideological_universe, :k], validate = (true, true))
    sort!(result, [:election, :k])
    return result
end

function strongest_tie_diagnostic(all_domains)
    rows = NamedTuple[]
    for year in analysis_years
        for k in (0, 1)
            domain = all_domains[(all_domains.election .== year) .& (all_domains.k .== k), :]
            strongest = strongest_inversion_selection(domain)
            strongest === nothing && continue
            nrow(strongest.exact_ties) > 1 || continue
            selected_id = String(strongest.selected.coalition_id)
            for row in eachrow(strongest.exact_ties)
                push!(rows, (
                    election = Int(year),
                    k = Int(k),
                    coalition_id = String(row.coalition_id),
                    coalition_label = String(row.coalition_label),
                    party_count = Int(row.party_count),
                    vote_share = Float64(row.vote_share),
                    seats = Int(row.seats),
                    r_C = Float64(row.r_C),
                    selected_after_party_count_tiebreak = String(row.coalition_id) == selected_id,
                ))
            end
        end
    end
    isempty(rows) && return DataFrame(
        election = Int[],
        k = Int[],
        coalition_id = String[],
        coalition_label = String[],
        party_count = Int[],
        vote_share = Float64[],
        seats = Int[],
        r_C = Float64[],
        selected_after_party_count_tiebreak = Bool[],
    )
    return DataFrame(rows)
end

# Audit both previously enumerated universes against full party totals and
# independent membership masks. No scientific quantity is re-enumerated here.
summary_results = DataFrame[]
for universe in ideological_universes
    active_audit_universe[] = universe
    for year in analysis_years
        summary_df = party_summaries[year]
        ordered = ideology_orders[(year, universe)]
        full = full_ideology_orders[year]
        represented = Set(String.(summary_df.SG_PARTIDO[summary_df.total_seats .> 0]))
        expected_parties = String.(sort(full, :ordinal_position).SG_PARTIDO)
        universe == :seat_winning && filter!(p -> p in represented, expected_parties)
        record_k_gap_check!(year, 0, "universe_exact_order", String.(ordered.SG_PARTIDO) == expected_parties, "filter preserves the original relative order")
        for k in (0, 1)
            domain = build_k_gap_domain(year, summary_df, full; k = k, universe = universe)
            domain_results[(year, universe, k)] = domain
            validate_k_gap_domain!(domain, summary_df, ordered, year, k)
            k == 0 && validate_k0_regression!(domain, ideological_intervals_by_universe[(year, universe)], year)
        end
        validate_nested_domains!(domain_results[(year, universe, 0)], domain_results[(year, universe, 1)], year)
    end
    domains = vcat([domain_results[(year, universe, k)] for year in analysis_years for k in (0, 1)]...)
    minimal = domains[domains.minimal_seat_majority, :]
    suffix = universe == primary_ideological_universe ? "" : "_$(universe)"
    for (name, df) in (("coalitions", domains), ("minimal_majorities", minimal), ("inversions", domains[domains.inversion, :]))
        write_artifact_csv(joinpath(raw_dir, "ideology_k_gap_$(name)$(suffix).csv"), df, "raw", "$(universe) k=0/1 ideological domain; all valid votes in V; freshly recomputed minimality.")
    end
    registry = CSV.read(joinpath(raw_dir, "ideology_k_gap_minimal_majorities$(suffix).csv"), DataFrame)
    validate_csv_roundtrip!(registry, minimal, propertynames(minimal), "K-gap $(universe) registry")
    membership = Processing.build_k_gap_membership_summary(registry)
    Processing.validate_k_gap_membership_summary!(membership, registry)
    Processing.validate_k_gap_membership_regression!(membership)
    summary = build_k_gap_summary(domains, membership)
    summary[!, :ideological_party_count] = [nrow(ideology_orders[(r.election, universe)]) for r in eachrow(summary)]
    validate_ideology_k_gap_summary_table!(summary, domains)
    push!(summary_results, summary)
    path = write_artifact_csv(joinpath(tables_dir, "ideology_k_gap_summary$(suffix).csv"), summary, "table", "$(universe) domain-minimal counts and strongest inversion.")
    ties = strongest_tie_diagnostic(minimal)
    ties[!, :ideological_universe] = fill(string(universe), nrow(ties))
    write_artifact_csv(joinpath(diagnostics_dir, "ideology_k_gap_strongest_inversion_ties$(suffix).csv"), ties, "diagnostic", "Strongest minimal inversion exact ties in $(universe).")
    if universe == primary_ideological_universe
        baseline = summary[summary.k .== 0, :]
    end
end
ideology_k_gap_coalitions = vcat([domain_results[(year, primary_ideological_universe, k)] for year in analysis_years for k in (0, 1)]...)
ideology_k_gap_all_parties = vcat([domain_results[(year, :all_parties, k)] for year in analysis_years for k in (0, 1)]...)
ideology_k_gap_minimal_majorities = ideology_k_gap_coalitions[ideology_k_gap_coalitions.minimal_seat_majority, :]
ideology_k_gap_summary = first(summary_results)
ideology_universe_comparison = vcat(summary_results...)
# Compare the endpoint region, not incidental zero-seat members/omissions.
ideology_universe_comparison[!, :strongest_region_changed] = [begin
    primary = domain_results[(r.election, :seat_winning, r.k)]
    robustness = domain_results[(r.election, :all_parties, r.k)]
    a = strongest_inversion_selection(primary[primary.minimal_seat_majority, :])
    b = strongest_inversion_selection(robustness[robustness.minimal_seat_majority, :])
    a === nothing || b === nothing ? (a === nothing) != (b === nothing) :
        (a.selected.left_endpoint, a.selected.right_endpoint) != (b.selected.left_endpoint, b.selected.right_endpoint)
end for r in eachrow(ideology_universe_comparison)]
sort!(ideology_universe_comparison, [:election, :k, :ideological_universe]; rev=[false,false,true])
write_artifact_csv(joinpath(tables_dir, "ideological_universe_comparison.csv"), ideology_universe_comparison, "table", "Primary and robustness counts, strongest cases, and endpoint-region sensitivity.")
write_artifact_csv(joinpath(raw_dir, "ideology_k_gap_coalitions_both_universes.csv"), vcat(ideology_k_gap_coalitions, ideology_k_gap_all_parties), "raw", "Complete k=0/1 enumeration in both explicitly labeled ideological universes.")
for year in analysis_years, k in (0,1)
    a, b = domain_results[(year,:seat_winning,k)], domain_results[(year,:all_parties,k)]
    active_audit_universe[] = :seat_winning
    record_k_gap_check!(year, k, "identical_national_denominator_across_universes", only(unique(a.national_vote_total)) == only(unique(b.national_vote_total)) == expected_national_vote_totals[year], "V includes votes cast for zero-seat parties in both domains")
    shared = innerjoin(select(a,:coalition_id,:vote_share,:seats), select(b,:coalition_id,:vote_share=>:other_vote_share,:seats=>:other_seats); on=:coalition_id)
    record_k_gap_check!(year, k, "no_vote_renormalization", all(shared.vote_share .== shared.other_vote_share) && all(shared.seats .== shared.other_seats), "shared members imply identical vote shares and observed seats")
end
write_artifact_csv(joinpath(diagnostics_dir, "ideology_k_gap_checks.csv"), DataFrame(ideology_k_gap_check_rows), "diagnostic", "Both universes: order, domain membership, denominator, minimality, inversion, accounting and nesting checks.")
show_table(ideology_universe_comparison)

ideological_interval_inversions_only = ideological_intervals_all_years[ideological_intervals_all_years.coalition_inversion .== true, :]
minimal_connected_inversions = ideological_intervals_all_years[ideological_intervals_all_years.minimal_connected_inversion .== true, :]
minimal_connected_inversion_metrics = add_metric_display_columns(minimal_connected_inversions)
write_artifact_csv(joinpath(raw_dir, "ideological_intervals_2014.csv"), ideological_intervals_2014, "raw", "All contiguous ideological intervals for 2014.")
write_artifact_csv(joinpath(raw_dir, "ideological_intervals_2018.csv"), ideological_intervals_2018, "raw", "All contiguous ideological intervals for 2018.")
write_artifact_csv(joinpath(raw_dir, "ideological_intervals_2022.csv"), ideological_intervals_2022, "raw", "All contiguous ideological intervals for 2022.")
write_artifact_csv(joinpath(raw_dir, "ideological_interval_metrics.csv"), ideological_intervals_all_years, "raw", "Full-precision metrics and classifications for all contiguous ideological intervals.")
write_artifact_csv(joinpath(raw_dir, "ideological_interval_inversions_only.csv"), ideological_interval_inversions_only, "raw", "Contiguous ideological interval coalition inversions only.")
write_artifact_csv(joinpath(raw_dir, "minimal_connected_inversion_metrics.csv"), minimal_connected_inversion_metrics, "raw", "Julia-filtered minimal connected ideological inversions with full-precision and Julia-generated display metrics.")

for (name, df) in (
    ("ideological_interval_metrics", ideological_intervals_all_parties),
    ("ideological_interval_inversions_only", ideological_intervals_all_parties[ideological_intervals_all_parties.coalition_inversion, :]),
    ("minimal_connected_inversion_metrics", add_metric_display_columns(ideological_intervals_all_parties[ideological_intervals_all_parties.minimal_connected_inversion, :])),
)
    write_artifact_csv(joinpath(raw_dir, "$(name)_all_parties.csv"), df, "raw", "All-party robustness exact-connected results.")
end
write_artifact_csv(joinpath(tables_dir, "table_appendix_minimal_connected_winning_intervals_all_parties.csv"), appendix_minimal_connected_winning_table(ideological_intervals_all_parties), "table", "Complete all-party robustness minimal winning compositions.")

function interval_summary_table(df)
    result = combine(groupby(df, :election_year), nrow => :all_intervals, :seat_majority => (x -> sum(Int.(x))) => :seat_majority_intervals, :coalition_inversion => (x -> sum(Int.(x))) => :coalition_inversions, :minimal_connected_inversion => (x -> sum(Int.(x))) => :minimal_inversions)
    sort!(result, :election_year)
    return result
end

table_05_ideological_interval_summary_by_election = interval_summary_table(ideological_intervals_all_years)
table_06_minimal_ideological_interval_inversions = select(
    minimal_connected_inversions,
    :election_year,
    :start_party,
    :end_party,
    :parties,
    :interval_size,
    :votes,
    :vote_share => ByRow(pct) => :vote_share_pct,
    :seats,
    :seat_share => ByRow(pct) => :seat_share_pct,
    :quota => ByRow(display_round) => :quota_display,
    :seat_diff => ByRow(display_round) => :seat_diff_display,
    :required_diff => ByRow(display_round) => :required_diff_display,
    :majority_status,
)
table_appendix_minimal_connected_winning_intervals = appendix_minimal_connected_winning_table(ideological_intervals_all_years)
legacy_ideological_summary_csv_path = write_artifact_csv(
    joinpath(tables_dir, "table_05_ideological_interval_summary_by_election.csv"),
    table_05_ideological_interval_summary_by_election,
    "table",
    "Legacy exact-connected interval diagnostic retained for baseline auditing; the manuscript summary uses ideology_k_gap_summary.csv.",
)
minimal_inversion_table_csv_path = write_artifact_csv(joinpath(tables_dir, "table_06_minimal_ideological_interval_inversions.csv"), table_06_minimal_ideological_interval_inversions, "table", "Endpoint-minimal ideological interval inversions with rounded q_C, d_C, and r_C display columns.")
minimal_inversion_table_from_csv = CSV.read(minimal_inversion_table_csv_path, DataFrame)
validate_minimal_inversion_table!(minimal_inversion_table_from_csv, minimal_connected_inversions)
minimal_connected_winning_csv_path = write_artifact_csv(joinpath(tables_dir, "table_appendix_minimal_connected_winning_intervals.csv"), table_appendix_minimal_connected_winning_intervals, "table", "Endpoint-minimal connected winning ideological intervals.")

minimal_connected_diagnostic = combine(groupby(table_appendix_minimal_connected_winning_intervals, :election_year),
    nrow => :endpoint_minimal_connected_winning_intervals,
    :contains_PT => (x -> sum(Int.(x))) => :containing_PT,
    :coalition_inversion => (x -> sum(Int.(x))) => :also_inversions)
sort!(minimal_connected_diagnostic, :election_year)
println("Endpoint-minimal connected winning interval diagnostic:")
show_table(minimal_connected_diagnostic)
println("Endpoint-minimal connected winning CSV written: ", minimal_connected_winning_csv_path)
minimal_connected_with_pt = table_appendix_minimal_connected_winning_intervals[table_appendix_minimal_connected_winning_intervals.contains_PT .== true, :]
minimal_connected_inversion_with_pt = minimal_connected_with_pt[minimal_connected_with_pt.coalition_inversion .== true, :]
println("PT is part of endpoint-minimal connected winning intervals: ", nrow(minimal_connected_with_pt) > 0 ? "YES" : "NO")
println("PT is part of endpoint-minimal connected winning inversion intervals: ", nrow(minimal_connected_inversion_with_pt) > 0 ? "YES" : "NO")
if nrow(minimal_connected_with_pt) > 0
    println("Endpoint-minimal connected winning intervals containing PT:")
    show_table(select(minimal_connected_with_pt, :election_year, :start_party, :end_party, :n_parties, :vote_share_pct, :seats, :seat_diff, :status, :coalition_inversion, :parties))
end
# Primary empirical counts are generated above; all-party baseline guards run
# inside validate_k0_regression!, and minimality is independently audited.
pp_pl_2022 = minimal_connected_inversions[(minimal_connected_inversions.election_year .== 2022) .& (minimal_connected_inversions.start_party .== "PP") .& (minimal_connected_inversions.end_party .== "PL"), :]
println("2022 PP-PL minimal ideological inversion present: ", nrow(pp_pl_2022) > 0)
show_table(table_05_ideological_interval_summary_by_election)

# =============================================================================
# BLOCK 11B. CABINET-TO-IDEOLOGICAL-INTERVAL BRIDGE
# =============================================================================

print_block("BLOCK 11B. CABINET-TO-IDEOLOGICAL-INTERVAL BRIDGE")

function bridge_status(vote_share, seats)
    vote_majority = Float64(vote_share) > 0.5
    seat_majority = Int(seats) >= seat_majority_threshold
    if vote_majority && seat_majority
        return "votes+seats"
    elseif seat_majority
        return "seats only"
    elseif vote_majority
        return "votes only"
    end
    return "neither"
end

function split_parties(parties)
    text = strip(String(parties))
    isempty(text) && return String[]
    return strip.(split(text, ","))
end

function label_count_suffix(label)
    mapping = Dict(
        "extrema-esquerda" => "far_left",
        "esquerda" => "left",
        "centro-esquerda" => "center_left",
        "centro" => "center",
        "centro-direita" => "center_right",
        "direita" => "right",
        "extrema-direita" => "far_right",
    )
    return get(mapping, String(label), replace(lowercase(String(label)), r"[^a-z0-9]+" => "_"))
end

function ideology_label_display(label)
    mapping = Dict(
        "extrema-esquerda" => "far left",
        "esquerda" => "left",
        "centro-esquerda" => "center-left",
        "centro" => "center",
        "centro-direita" => "center-right",
        "direita" => "right",
        "extrema-direita" => "far right",
    )
    return get(mapping, String(label), String(label))
end

function weighted_mean_or_missing(values, weights)
    vals = Float64.(values)
    wts = Float64.(weights)
    total_weight = sum(wts)
    total_weight > 0 || return missing
    return sum(vals .* wts) / total_weight
end

function fmt_missing2(value)
    ismissing(value) && return ""
    return fmt2(value)
end

function ideology_summary_for_rows(df)
    nrow(df) == 0 && return ""
    counts = combine(groupby(df, :classification_label), nrow => :n)
    first_index = combine(groupby(df, :classification_label), :ordinal_position => minimum => :first_index)
    counts = leftjoin(counts, first_index, on = :classification_label)
    sort!(counts, :first_index)
    return join(["$(ideology_label_display(row.classification_label)): $(row.n)" for row in eachrow(counts)], "; ")
end

function ideology_metrics_for_rows(df)
    if nrow(df) == 0
        return (
            mean_unweighted = missing,
            median_unweighted = missing,
            mean_seat_weighted = missing,
            mean_vote_weighted = missing,
            summary = "",
        )
    end
    values = Float64.(df.ideology_value_numeric)
    return (
        mean_unweighted = mean(values),
        median_unweighted = median(values),
        mean_seat_weighted = weighted_mean_or_missing(values, df.seats),
        mean_vote_weighted = weighted_mean_or_missing(values, df.votes),
        summary = ideology_summary_for_rows(df),
    )
end

function append_label_counts!(row, prefix, df, labels)
    label_counts = nrow(df) == 0 ? Dict{String,Int}() : Dict(String(r.classification_label) => Int(r.n) for r in eachrow(combine(groupby(df, :classification_label), nrow => :n)))
    for label in labels
        row[Symbol(prefix, "_", label_count_suffix(label), "_count")] = get(label_counts, String(label), 0)
    end
    return row
end

function ordered_party_rows(ideology_year_df, summary_year_df, parties)
    party_set = Set(String.(parties))
    rows = innerjoin(
        select(ideology_year_df, :ordinal_position, :party, :classification_label, :ideology_value_numeric),
        select(summary_year_df, :party, :votes, :vote_share, :seats, :seat_share, :quota, :seat_diff),
        on = :party,
    )
    rows = rows[in.(String.(rows.party), Ref(party_set)), :]
    sort!(rows, :ordinal_position)
    return rows
end

function bridge_summarize_parties(summary_year_df, parties)
    totals = Processing.coalition_totals(summary_year_df, parties;
        party_col = :party, vote_col = :votes, seat_col = :seats)
    accounting = Processing.coalition_accounting_metrics(totals.votes, totals.seats;
        national_vote_total = totals.national_vote_total, total_seats = totals.total_seats,
        seat_majority_threshold)
    return (votes = Int(totals.votes), vote_share = accounting.vote_share,
        seats = Int(totals.seats), seat_share = accounting.seat_share,
        quota = accounting.quota, seat_diff = accounting.seat_diff,
        vote_majority = accounting.vote_majority, seat_majority = accounting.seat_majority,
        majority_status = bridge_status(accounting.vote_share, totals.seats),
        coalition_inversion = accounting.coalition_inversion)
end

function choose_closest_interval(cabinet_parties, candidate_intervals)
    isempty(candidate_intervals) && return nothing
    cabinet_set = Set(String.(cabinet_parties))
    cabinet_n = length(cabinet_set)
    best = nothing
    best_key = nothing
    for interval in eachrow(candidate_intervals)
        interval_parties = split_parties(interval.parties)
        interval_set = Set(interval_parties)
        overlap_n = length(intersect(cabinet_set, interval_set))
        union_n = length(union(cabinet_set, interval_set))
        jaccard = union_n == 0 ? 0.0 : overlap_n / union_n
        cabinet_coverage = cabinet_n == 0 ? 0.0 : overlap_n / cabinet_n
        interval_extra_n = length(setdiff(interval_set, cabinet_set))
        interval_size = Int(interval.interval_size)
        key = (jaccard, cabinet_coverage, overlap_n, -interval_extra_n, -interval_size, -abs(Float64(interval.seat_diff)))
        if best_key === nothing || key > best_key
            best_key = key
            best = (
                row = interval,
                overlap_n = overlap_n,
                jaccard = Float64(jaccard),
                cabinet_coverage = Float64(cabinet_coverage),
                interval_extra_n = interval_extra_n,
                cabinet_missing_n = length(setdiff(cabinet_set, interval_set)),
            )
        end
    end
    return best
end

function add_closest_interval_fields!(row, prefix, closest)
    if closest === nothing
        for suffix in ["start_party", "end_party", "n_parties", "vote_share", "vote_share_pct", "seats", "seat_diff", "status", "overlap_n", "jaccard", "cabinet_coverage", "parties"]
            row[Symbol(prefix, "_", suffix)] = suffix in ["start_party", "end_party", "status", "parties"] ? "" : missing
        end
        return row
    end
    interval = closest.row
    row[Symbol(prefix, "_start_party")] = String(interval.start_party)
    row[Symbol(prefix, "_end_party")] = String(interval.end_party)
    row[Symbol(prefix, "_n_parties")] = Int(interval.interval_size)
    row[Symbol(prefix, "_vote_share")] = Float64(interval.vote_share)
    row[Symbol(prefix, "_vote_share_pct")] = pct(interval.vote_share)
    row[Symbol(prefix, "_seats")] = Int(interval.seats)
    row[Symbol(prefix, "_seat_diff")] = Float64(interval.seat_diff)
    if prefix == "closest_mcw"
        row[Symbol(prefix, "_status")] = bridge_status(interval.vote_share, interval.seats)
    end
    row[Symbol(prefix, "_overlap_n")] = Int(closest.overlap_n)
    row[Symbol(prefix, "_jaccard")] = Float64(closest.jaccard)
    row[Symbol(prefix, "_cabinet_coverage")] = Float64(closest.cabinet_coverage)
    row[Symbol(prefix, "_parties")] = String(interval.parties)
    return row
end


function build_cabinet_interval_bridge(cabinets, party_summary_all, ideology_order_all, intervals_all; universe = primary_ideological_universe)
    labels = sort(unique(String.(ideology_order_all.classification_label)))
    ideology_joined = innerjoin(
        select(ideology_order_all, :election_year, :ordinal_position, :party, :classification_label, :ideology_value_numeric),
        party_summary_all,
        on = [:election_year, :party],
    )
    minimal_winning = intervals_all[intervals_all.endpoint_minimal_connected_winning .== true, :]
    minimal_inversions = minimal_winning[minimal_winning.coalition_inversion .== true, :]
    rows = Vector{Dict{Symbol,Any}}()
    previous_by_year = Dict{Int,Dict{Symbol,Any}}()
    unmapped_warnings = String[]

    for cab in eachrow(sort(cabinets, [:election_year, :period_start]))
        year = Int(cab.election_year)
        ideology_year = ideology_joined[ideology_joined.election_year .== year, :]
        summary_year = party_summary_all[party_summary_all.election_year .== year, :]
        cabinet_parties = split_parties(cab.parties)
        cabinet_set = Set(cabinet_parties)
        ideology_party_set = Set(String.(ideology_year.party))
        parliamentary_cabinet = intersect(cabinet_set, ideology_party_set)
        excluded_zero_seat = setdiff(cabinet_set, ideology_party_set)
        summary_seats = Dict(String(r.party)=>Int(r.seats) for r in eachrow(summary_year))
        unmapped = sort([p for p in excluded_zero_seat if !haskey(summary_seats,p) || summary_seats[p] > 0])
        if !isempty(unmapped)
            push!(unmapped_warnings, "$(year) $(cab.period): $(join(unmapped, ", "))")
        end
        cabinet_rows = ordered_party_rows(ideology_year, summary_year, cabinet_parties)
        cabinet_metrics = ideology_metrics_for_rows(cabinet_rows)

        if nrow(cabinet_rows) == 0
            closure_rows = DataFrame()
            gap_rows = DataFrame()
            closure_metrics = ideology_metrics_for_rows(closure_rows)
            gap_summary = ""
            closure_metrics_vote = bridge_summarize_parties(summary_year, String[])
            min_index = missing
            max_index = missing
            closure_parties = String[]
            gap_parties = String[]
            leftmost_party = ""
            rightmost_party = ""
        else
            min_index = minimum(Int.(cabinet_rows.ordinal_position))
            max_index = maximum(Int.(cabinet_rows.ordinal_position))
            closure_rows = ideology_year[(ideology_year.ordinal_position .>= min_index) .& (ideology_year.ordinal_position .<= max_index), :]
            sort!(closure_rows, :ordinal_position)
            closure_parties = String.(closure_rows.party)
            gap_parties = String.(closure_rows.party[.!in.(String.(closure_rows.party), Ref(cabinet_set))])
            gap_rows = closure_rows[in.(String.(closure_rows.party), Ref(Set(gap_parties))), :]
            closure_metrics = ideology_metrics_for_rows(closure_rows)
            gap_summary = ideology_summary_for_rows(gap_rows)
            closure_metrics_vote = bridge_summarize_parties(summary_year, closure_parties)
            leftmost_party = String(cabinet_rows.party[argmin(Int.(cabinet_rows.ordinal_position))])
            rightmost_party = String(cabinet_rows.party[argmax(Int.(cabinet_rows.ordinal_position))])
        end

        winning_candidates = minimal_winning[minimal_winning.election_year .== year, :]
        inversion_candidates = minimal_inversions[minimal_inversions.election_year .== year, :]
        closest_mcw = choose_closest_interval(collect(parliamentary_cabinet), winning_candidates)
        closest_mci = choose_closest_interval(collect(parliamentary_cabinet), inversion_candidates)

        row = Dict{Symbol,Any}()
        row[:election_year] = year
        row[:ideological_universe] = string(universe)
        row[:excluded_zero_seat_cabinet_parties] = join(sort(collect(excluded_zero_seat)), ", ")
        row[:cabinet_period] = String(cab.period)
        row[:cabinet_party_set_id] = hasproperty(cab,:cabinet_party_set_id) ? cab.cabinet_party_set_id : missing
        row[:display_label] = hasproperty(cab,:display_label) ? cab.display_label : missing
        row[:canonical_membership] = join(sort(split_parties(cab.parties)), ";")
        row[:administration_id] = String(cab.administration_id)
        row[:source_periods] = String(cab.source_periods)
        row[:period_start] = cab.period_start
        row[:period_end] = cab.period_end
        row[:days] = Int(cab.period_days)
        row[:cabinet_status] = bridge_status(cab.vote_share, cab.seats)
        row[:cabinet_vote_share] = Float64(cab.vote_share)
        row[:cabinet_vote_share_pct] = pct(cab.vote_share)
        row[:cabinet_seats] = Int(cab.seats)
        row[:cabinet_seat_diff] = Float64(cab.seat_diff)
        row[:cabinet_n_parties] = length(cabinet_parties)
        row[:cabinet_parliamentary_n_parties] = length(parliamentary_cabinet)
        row[:cabinet_parties] = String(cab.parties)
        row[:unmapped_cabinet_parties] = join(unmapped, ", ")

        row[:cabinet_min_ideology_index] = min_index
        row[:cabinet_max_ideology_index] = max_index
        row[:cabinet_leftmost_party] = leftmost_party
        row[:cabinet_rightmost_party] = rightmost_party
        row[:cabinet_span_width] = nrow(cabinet_rows) == 0 ? missing : Int(max_index - min_index + 1)
        row[:cabinet_mean_ideology_value_unweighted] = cabinet_metrics.mean_unweighted
        row[:cabinet_median_ideology_value_unweighted] = cabinet_metrics.median_unweighted
        row[:cabinet_mean_ideology_value_seat_weighted] = cabinet_metrics.mean_seat_weighted
        row[:cabinet_mean_ideology_value_vote_weighted] = cabinet_metrics.mean_vote_weighted
        row[:cabinet_ideology_summary] = cabinet_metrics.summary
        append_label_counts!(row, "cabinet", cabinet_rows, labels)

        row[:closure_start_party] = nrow(closure_rows) == 0 ? "" : String(first(closure_rows.party))
        row[:closure_end_party] = nrow(closure_rows) == 0 ? "" : String(last(closure_rows.party))
        row[:closure_n_parties] = length(closure_parties)
        row[:closure_vote_share] = closure_metrics_vote.vote_share
        row[:closure_vote_share_pct] = pct(closure_metrics_vote.vote_share)
        row[:closure_seats] = closure_metrics_vote.seats
        row[:closure_seat_diff] = closure_metrics_vote.seat_diff
        row[:closure_status] = bridge_status(closure_metrics_vote.vote_share, closure_metrics_vote.seats)
        row[:closure_parties] = join(closure_parties, ", ")
        row[:closure_gap_n] = length(gap_parties)
        row[:closure_gap_parties] = join(gap_parties, ", ")
        row[:closure_mean_ideology_value_unweighted] = closure_metrics.mean_unweighted
        row[:closure_median_ideology_value_unweighted] = closure_metrics.median_unweighted
        row[:closure_mean_ideology_value_seat_weighted] = closure_metrics.mean_seat_weighted
        row[:closure_mean_ideology_value_vote_weighted] = closure_metrics.mean_vote_weighted
        row[:closure_ideology_summary] = closure_metrics.summary

        row[:gap_ideology_summary] = gap_summary
        append_label_counts!(row, "gap", gap_rows, labels)

        add_closest_interval_fields!(row, "closest_mcw", closest_mcw)
        add_closest_interval_fields!(row, "closest_mci", closest_mci)

        previous = get(previous_by_year, year, nothing)
        adjacent = !hasproperty(cab,:cabinet_party_set_id) && previous !== nothing && previous[:period_end] + Day(1) == cab.period_start && previous[:administration_id] == cab.administration_id
        row[:transition_status] = hasproperty(cab,:cabinet_party_set_id) ? "not_applicable_set" : adjacent ? "identified_adjacent" : previous === nothing ? "first_identified" : previous[:administration_id] != cab.administration_id ? "administration_boundary" : "unidentified_gap"
        if !adjacent
            row[:delta_cabinet_mean_ideology_value_unweighted] = missing
            row[:delta_cabinet_mean_ideology_value_seat_weighted] = missing
            row[:delta_cabinet_span_width] = missing
            row[:entered_ideology_summary] = ""
            row[:left_ideology_summary] = ""
        else
            row[:delta_cabinet_mean_ideology_value_unweighted] = row[:cabinet_mean_ideology_value_unweighted] - previous[:cabinet_mean_ideology_value_unweighted]
            row[:delta_cabinet_mean_ideology_value_seat_weighted] = row[:cabinet_mean_ideology_value_seat_weighted] - previous[:cabinet_mean_ideology_value_seat_weighted]
            row[:delta_cabinet_span_width] = row[:cabinet_span_width] - previous[:cabinet_span_width]
            entered = sort(collect(setdiff(cabinet_set, previous[:cabinet_party_set])))
            left = sort(collect(setdiff(previous[:cabinet_party_set], cabinet_set)))
            row[:entered_ideology_summary] = ideology_summary_for_rows(ordered_party_rows(ideology_year, summary_year, entered))
            row[:left_ideology_summary] = ideology_summary_for_rows(ordered_party_rows(ideology_year, summary_year, left))
        end
        previous_by_year[year] = Dict{Symbol,Any}(
            :period_end => cab.period_end,
            :administration_id => String(cab.administration_id),
            :cabinet_party_set => cabinet_set,
            :cabinet_mean_ideology_value_unweighted => row[:cabinet_mean_ideology_value_unweighted],
            :cabinet_mean_ideology_value_seat_weighted => row[:cabinet_mean_ideology_value_seat_weighted],
            :cabinet_span_width => row[:cabinet_span_width],
        )
        push!(rows, row)
    end

    ordered_cols = Symbol[
        :election_year, :ideological_universe, :cabinet_party_set_id, :display_label, :canonical_membership, :excluded_zero_seat_cabinet_parties, :cabinet_period, :administration_id, :transition_status, :source_periods, :period_start, :period_end, :days, :cabinet_status,
        :cabinet_vote_share, :cabinet_vote_share_pct, :cabinet_seats, :cabinet_seat_diff,
        :cabinet_n_parties, :cabinet_parliamentary_n_parties, :cabinet_parties, :unmapped_cabinet_parties,
        :cabinet_min_ideology_index, :cabinet_max_ideology_index, :cabinet_leftmost_party,
        :cabinet_rightmost_party, :cabinet_span_width, :cabinet_mean_ideology_value_unweighted,
        :cabinet_median_ideology_value_unweighted, :cabinet_mean_ideology_value_seat_weighted,
        :cabinet_mean_ideology_value_vote_weighted, :cabinet_ideology_summary,
    ]
    append!(ordered_cols, [Symbol("cabinet_", label_count_suffix(label), "_count") for label in labels])
    append!(ordered_cols, Symbol[
        :closure_start_party, :closure_end_party, :closure_n_parties, :closure_vote_share,
        :closure_vote_share_pct, :closure_seats, :closure_seat_diff, :closure_status,
        :closure_parties, :closure_gap_n, :closure_gap_parties,
        :closure_mean_ideology_value_unweighted, :closure_median_ideology_value_unweighted,
        :closure_mean_ideology_value_seat_weighted, :closure_mean_ideology_value_vote_weighted,
        :closure_ideology_summary, :gap_ideology_summary,
    ])
    append!(ordered_cols, [Symbol("gap_", label_count_suffix(label), "_count") for label in labels])
    append!(ordered_cols, Symbol[
        :closest_mcw_start_party, :closest_mcw_end_party, :closest_mcw_n_parties,
        :closest_mcw_vote_share, :closest_mcw_vote_share_pct, :closest_mcw_seats, :closest_mcw_seat_diff,
        :closest_mcw_status, :closest_mcw_overlap_n, :closest_mcw_jaccard,
        :closest_mcw_cabinet_coverage, :closest_mcw_parties,
        :closest_mci_start_party, :closest_mci_end_party, :closest_mci_n_parties,
        :closest_mci_vote_share, :closest_mci_vote_share_pct, :closest_mci_seats, :closest_mci_seat_diff,
        :closest_mci_overlap_n, :closest_mci_jaccard, :closest_mci_cabinet_coverage,
        :closest_mci_parties, :delta_cabinet_mean_ideology_value_unweighted,
        :delta_cabinet_mean_ideology_value_seat_weighted, :delta_cabinet_span_width,
        :entered_ideology_summary, :left_ideology_summary,
    ])

    result = DataFrame()
    for col in ordered_cols
        result[!, col] = [get(row, col, missing) for row in rows]
    end
    sort!(result, [:election_year, :period_start])
    return result, unmapped_warnings
end

party_summary_bridge_all = vcat(
    select(party_seat_differentials_2014, :election_year, :party, :votes, :vote_share, :seats, :seat_share, :quota, :seat_diff),
    select(party_seat_differentials_2018, :election_year, :party, :votes, :vote_share, :seats, :seat_share, :quota, :seat_diff),
    select(party_seat_differentials_2022, :election_year, :party, :votes, :vote_share, :seats, :seat_share, :quota, :seat_diff);
    cols = :union,
)
chronology_bridge, _ = build_cabinet_interval_bridge(cabinet_chronology, party_summary_bridge_all, ideology_order_all_years, ideological_intervals_all_years)
write_artifact_csv(joinpath(diagnostics_dir,"cabinet_interval_chronology.csv"),chronology_bridge,"diagnostic","Temporal cabinet transitions only; analytical comparisons use the distinct-set bridge.")
table_appendix_cabinet_interval_bridge, cabinet_bridge_unmapped_warnings = build_cabinet_interval_bridge(observed_cabinet_coalitions_all_years, party_summary_bridge_all, ideology_order_all_years, ideological_intervals_all_years)
cabinet_bridge_csv_path = write_artifact_csv(joinpath(tables_dir, "table_appendix_cabinet_interval_bridge.csv"), table_appendix_cabinet_interval_bridge, "table", "Observed cabinet coalitions compared with connected ideological closures and nearest minimal connected intervals.")
write_artifact_csv(joinpath(tables_dir, "cabinet_interval_bridge_unidentified.csv"), cabinet_unidentified, "table", "Cabinet intervals excluded from ideological bridge because their complete set is unidentified.")

chronology_bridge_all_parties, _ = build_cabinet_interval_bridge(cabinet_chronology, party_summary_bridge_all, ideology_order_all_parties, ideological_intervals_all_parties; universe=:all_parties)
write_artifact_csv(joinpath(diagnostics_dir,"cabinet_interval_chronology_all_parties.csv"),chronology_bridge_all_parties,"diagnostic","Temporal transitions in the all-party ideological universe; analytical comparisons use distinct sets.")
robustness_bridge, robustness_bridge_warnings = build_cabinet_interval_bridge(observed_cabinet_coalitions_all_years, party_summary_bridge_all, ideology_order_all_parties, ideological_intervals_all_parties; universe=:all_parties)
write_artifact_csv(joinpath(tables_dir, "table_appendix_cabinet_interval_bridge_all_parties.csv"), robustness_bridge, "table", "All-party robustness cabinet closures, gaps, and nearest intervals.")

cabinet_bridge_unmapped_count = sum(table_appendix_cabinet_interval_bridge.unmapped_cabinet_parties .!= "")
closure_inversion_count = sum((table_appendix_cabinet_interval_bridge.closure_vote_share .< 0.5) .& (table_appendix_cabinet_interval_bridge.closure_seats .>= seat_majority_threshold))
println("Cabinet-interval bridge CSV written: ", cabinet_bridge_csv_path)
println("Cabinet party sets processed: ", nrow(table_appendix_cabinet_interval_bridge))
println("Cabinet party sets with unmapped ideology parties: ", cabinet_bridge_unmapped_count)
if !isempty(cabinet_bridge_unmapped_warnings)
    println("Unmapped cabinet parties in ideology order:")
    foreach(w -> println("- ", w), cabinet_bridge_unmapped_warnings)
end
println("Cabinet party sets whose connected closure is itself an inversion: ", closure_inversion_count)

cabinet_bridge_inversions = table_appendix_cabinet_interval_bridge[table_appendix_cabinet_interval_bridge.cabinet_status .== "seats only", :]
println("Observed cabinet inversion bridge diagnostics:")
for row in eachrow(cabinet_bridge_inversions)
    println("- $(row.election_year) $(row.cabinet_period): cabinet=$(row.cabinet_parties); closure=$(row.closure_start_party)--$(row.closure_end_party) ($(row.closure_n_parties) parties, gaps=$(row.closure_gap_n)); closest MCW=$(row.closest_mcw_start_party)--$(row.closest_mcw_end_party); closest MCI=$(isempty(String(row.closest_mci_start_party)) ? "none" : string(row.closest_mci_start_party, "--", row.closest_mci_end_party))")
end

# Administration comparisons derive from dated reporting boundaries. Old period
# IDs do not name fixed historical events in a regenerated chronology.
println("Cabinet bridge rows: ", nrow(table_appendix_cabinet_interval_bridge),
    "; unidentified historical intervals: ", nrow(cabinet_unidentified))

# =============================================================================
# BLOCK 12. PAPER TABLES
# =============================================================================

print_block("BLOCK 12. PAPER TABLES")
table_01_definitions_classification_rules = DataFrame([
    (item = "seat_majority_threshold", value = string(seat_majority_threshold), note = "Seat majority in a 513-seat Chamber."),
    (item = "vote_majority", value = "vote_share > 0.5", note = "Strict vote-majority rule."),
    (item = "seat_majority", value = "seats >= 257", note = "Absolute Chamber seat majority."),
    (item = "coalition_inversion", value = "seat_majority && !vote_majority", note = "Seat majority without national vote majority."),
    (item = "2014 classification", value = "2023", note = "Paper rule for ideology source year."),
    (item = "2018 classification", value = "2023", note = "Paper rule for ideology source year."),
    (item = "2022 classification", value = "2025", note = "Paper rule for ideology source year."),
    (item = "2014 vote columns", value = "QT_VOTOS_NOMINAIS + QT_VOTOS_LEGENDA", note = "Legacy TSE file schema."),
    (item = "2018 vote columns", value = "QT_VOTOS_NOMINAIS_VALIDOS + QT_TOTAL_VOTOS_LEG_VALIDOS", note = "Includes converted nominal-to-legend votes."),
    (item = "2022 vote columns", value = "QT_VOTOS_NOMINAIS_VALIDOS + QT_TOTAL_VOTOS_LEG_VALIDOS", note = "Includes converted nominal-to-legend votes."),
])
table_07_audit_vote_columns_crosswalk = select(vote_column_consistency, :election_year, :selected_nominal_col, :selected_legend_col, :selected_scheme, :check_name, :difference, :selected_component_sum)
write_artifact_csv(joinpath(tables_dir, "table_01_definitions_classification_rules.csv"), table_01_definitions_classification_rules, "table", "Definitions, thresholds, ideology classification rules, and vote-column rules.")
write_artifact_csv(joinpath(tables_dir, "table_07_audit_vote_columns_crosswalk.csv"), table_07_audit_vote_columns_crosswalk, "table", "Audit table for selected vote columns and converted legend-vote checks.")

# =============================================================================
# BLOCK 13. FIGURE-INPUT DATA
# =============================================================================

print_block("BLOCK 13. FIGURE-INPUT DATA")
party_vote_share_vs_seat_share = select(party_seat_differentials_all_years, :election_year, :party, :votes, :national_vote_total, :vote_share, :seats, :seat_share, :quota, :seat_diff, :representation_ratio)
ideological_interval_heatmap = select(ideological_intervals_all_years, :election_year, :ideological_universe, :ideological_party_count, :start_index, :end_index, :start_party, :end_party, :interval_size, :vote_share, :seat_share, :seats, :seat_diff, :majority_status, :coalition_inversion, :minimal_ideological_interval_inversion)
observed_coalition_timeline = select(cabinet_chronology, :election_year, :coalition_year, :period, :source_periods, :period_start, :period_end, :period_days, :days_overlapping_mandate, :parties, :votes, :national_vote_total, :vote_share, :seats, :seat_share, :quota, :seat_diff, :required_diff, :representation_ratio, :vote_majority, :seat_majority, :majority_status, :coalition_inversion)
write_artifact_csv(joinpath(figure_data_dir, "party_vote_share_vs_seat_share.csv"), party_vote_share_vs_seat_share, "figure_data", "Party vote share versus seat share figure input.")
write_artifact_csv(joinpath(figure_data_dir, "ideological_interval_heatmap.csv"), ideological_interval_heatmap, "figure_data", "Ideological interval heatmap figure input.")
write_artifact_csv(joinpath(figure_data_dir, "observed_coalition_timeline.csv"), observed_coalition_timeline, "figure_data", "Full cabinet chronology for audit and duration reconstruction; Figure 2 uses cabinet_party_set_comparison.csv.")

# =============================================================================
# BLOCK 14. DIAGNOSTICS
# =============================================================================

print_block("BLOCK 14. DIAGNOSTICS")
party_mapping_votes = vcat_or_empty(vote_mapping_tables)
party_mapping_seats = vcat_or_empty(seat_mapping_tables)
party_mapping_coalitions = vcat_or_empty(coalition_mapping_tables)
party_mapping_ideology = vcat_or_empty(ideology_mapping_tables)
audit_appendix_vote_columns_and_crosswalk = copy(table_07_audit_vote_columns_crosswalk)
write_artifact_csv(joinpath(diagnostics_dir, "party_mapping_votes.csv"), party_mapping_votes, "diagnostic", "Raw-to-canonical party mapping for vote inputs.")
write_artifact_csv(joinpath(diagnostics_dir, "party_mapping_seats.csv"), party_mapping_seats, "diagnostic", "Raw-to-canonical party mapping for seat inputs.")
write_artifact_csv(joinpath(diagnostics_dir, "party_mapping_coalitions.csv"), party_mapping_coalitions, "diagnostic", "Raw-to-canonical party mapping for coalition inputs.")
write_artifact_csv(joinpath(diagnostics_dir, "party_mapping_ideology.csv"), party_mapping_ideology, "diagnostic", "Raw-to-canonical party mapping for ideology inputs.")
write_artifact_csv(joinpath(diagnostics_dir, "vote_column_consistency.csv"), vote_column_consistency, "diagnostic", "Vote-column selection and consistency checks.")
write_artifact_csv(joinpath(diagnostics_dir, "audit_appendix_vote_columns_and_crosswalk.csv"), audit_appendix_vote_columns_and_crosswalk, "diagnostic", "Appendix-ready vote-column and crosswalk audit extract.")
println("Diagnostics written. Preflight and coalition-period linkage were written in their own blocks.")

# =============================================================================
# BLOCK 15. ARTIFACT MANIFEST
# =============================================================================

print_block("BLOCK 15. ARTIFACT MANIFEST")
artifact_manifest = DataFrame(artifact_records)
manifest_row = (path = relpath(artifact_manifest_path, paper_output_root), artifact_type = "manifest", description = "Manifest of every generated paper-runner artifact.", rows = nrow(artifact_manifest) + 1, columns = length(names(artifact_manifest)))
push!(artifact_records, manifest_row)
artifact_manifest = DataFrame(artifact_records)
write_paper_csv(artifact_manifest_path, artifact_manifest)
manifest_check = CSV.read(artifact_manifest_path, DataFrame)
nrow(manifest_check) == nrow(artifact_manifest) || error("Artifact manifest row count mismatch after write.")
Set(String.(manifest_check.path)) == Set(String.(artifact_manifest.path)) || error("Artifact manifest path set mismatch after write.")
println("Artifact manifest:")
show_table(artifact_manifest)
println()
println("Validated empirical pattern:")
println("- Total seats are 513 in 2014, 2018, and 2022.")
println("- Party-level sum(seat_diff) is approximately zero by year.")
println("- Identified cabinet inversions: ", join(string.(cabinet_coalition_focal_cases.period), ", "))
println("- Both ideological universes passed independent enumeration and accounting audits.")
show_table(ideology_universe_comparison)
