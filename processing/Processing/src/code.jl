# =============================================================================
# Root configuration and paths (simple, explicit)
# =============================================================================

const RAW_ROOT = Ref("../data/raw/electionsBR")
const COALITION_PATH = Ref(CabinetRelease.default_pin_path())

"""
    set_root!(path::AbstractString)

Define o diretório raiz onde estão as pastas por ano (1998, 2002, ...).
"""
set_root!(p::AbstractString) = (RAW_ROOT[] = String(p))

"""
    get_root() :: String

Retorna o diretório raiz atualmente configurado.
"""
get_root() = RAW_ROOT[]

"""
    set_coalition_path!(path::AbstractString)

Define o caminho para `partidos_por_periodo.json`.
"""
set_coalition_path!(p::AbstractString) = (COALITION_PATH[] = String(p))

"""
    get_coalition_path() :: String

Retorna o caminho atualmente configurado para `partidos_por_periodo.json`.
"""
get_coalition_path() = COALITION_PATH[]

# Caminhos específicos para cada arquivo TSE que nos interessa.
pmz_path(year::Integer)       = joinpath(get_root(), string(year), "party_mun_zone.csv")
candidate_path(year::Integer) = joinpath(get_root(), string(year), "candidate.csv")
seats_path(year::Integer)     = joinpath(get_root(), string(year), "seats.csv")

# =============================================================================
# Pequenos normalizadores (sem mágica, só o necessário)
# =============================================================================

"""
    upper_strip!(df, col)

Converte a coluna `col` para String, faz strip e uppercase in-place.
"""
function upper_strip!(df, col::Symbol)
    df[!, col] = uppercase.(strip.(String.(df[!, col])))
    return df
end

"""
    stringify!(df, col)

Converte a coluna `col` para String in-place.
"""
function stringify!(df, col::Symbol)
    df[!, col] = String.(df[!, col])
    return df
end

"""
    normalize_party_str(x) :: String

Normaliza uma sigla/label de partido usando regras canônicas determinísticas.
"""
function normalize_party_str(
    x;
    year::Union{Int,Nothing}=nothing,
)
    year_kw = year === nothing ? missing : Int(year)
    return canonical_party(String(x); year = year_kw, strict = true)
end

"""
    normalize_party!(df; col=:SG_PARTIDO)

Aplica canonicalização na coluna de partido.
"""
function normalize_party!(
    df;
    col::Union{Symbol,AbstractString} = :SG_PARTIDO,
    year::Union{Int,Nothing} = nothing,
)
    source_vals = String.(df[!, col])
    unique_vals = unique(source_vals)
    year_kw = year === nothing ? missing : Int(year)
    mapped = canonicalize_parties(unique_vals; year = year_kw, strict = true, with_mapping = true)
    canon_map = Dict(String(row.alias_raw) => String(row.canonical) for row in eachrow(mapped.mapping))
    df[!, col] = [canon_map[raw] for raw in source_vals]
    return df
end

"""
    to_int(x) :: Int

Converte vários tipos em Int, tratando missing/nothing como 0.
Evita explodir se alguma coluna vier como String.
"""
function to_int(x)
    if x === missing || x === nothing
        return 0
    elseif x isa Integer
        return x
    elseif x isa AbstractFloat
        return round(Int, x)
    else
        y = tryparse(Int, String(x))
        return y === nothing ? 0 : y
    end
end

# =============================================================================
# Column detection helpers
# =============================================================================

function first_in_df(df::DataFrame, cands::Vector{String})
    nn = names(df)
    by_name = Dict(uppercase(strip(String(n))) => n for n in nn)
    for c in cands
        key = uppercase(strip(String(c)))
        if haskey(by_name, key)
            return by_name[key]
        end
    end
    return nothing
end

function pick_col(df::DataFrame, col::Union{Symbol,AbstractString,Nothing})
    col === nothing && return nothing
    return first_in_df(df, [String(col)])
end

function detect_vote_cols(df::DataFrame;
    nom_col = nothing,
    leg_col = nothing,
    total_col = nothing,
)
    nom = pick_col(df, nom_col)
    leg = pick_col(df, leg_col)
    total = pick_col(df, total_col)

    if total_col !== nothing && total !== nothing && nom === nothing && leg === nothing
        return (nothing, nothing, total, :total)
    end

    if nom === nothing
        nom = first_in_df(df, ["QT_VOTOS_NOMINAIS_VALIDOS",
                               "QT_VOTOS_NOMINAIS"])
    end

    if leg === nothing
        leg = first_in_df(df, ["QT_TOTAL_VOTOS_LEG_VALIDOS",
                               "QT_VOTOS_LEGENDA_VALIDOS",
                               "QT_VOTOS_LEGENDA"])
    end

    if nom !== nothing && leg !== nothing
        scheme =
            uppercase(strip(String(nom))) == "QT_VOTOS_NOMINAIS_VALIDOS" &&
            uppercase(strip(String(leg))) == "QT_TOTAL_VOTOS_LEG_VALIDOS" ?
            :nominal_valid_plus_total_valid_legend :
            :nominal_plus_legend_legacy
        return (nom, leg, total, scheme)
    end

    error("Could not identify party vote components for party_mun_zone.")
end

# Candidate rows in the frozen inputs are already candidate-unique. Count only
# these accepted exact winner statuses; do not reinterpret retotalizations.
const WINNER_STATUSES = Set(["ELEITO", "ELEITO POR QP", "ELEITO POR MEDIA", "ELEITO POR MÉDIA"])

function party_summary(votes::DataFrame,
                       seats::DataFrame;
                       vote_col::Symbol = :valid_total,
                       seat_col::Symbol = :total_seats,
                       expected_total_seats::Union{Int,Nothing} = nothing)

    df = outerjoin(votes, seats, on = :SG_PARTIDO)

    # if any party has votes or seats missing, treat as 0
    df[!, vote_col] = coalesce.(df[!, vote_col], 0)
    df[!, seat_col] = coalesce.(df[!, seat_col], 0)

    total_votes = sum(df[!, vote_col])
    total_seats = sum(df[!, seat_col])

    total_votes > 0 || error("party_summary: total votes must be positive.")
    total_seats > 0 || error("party_summary: total seats must be positive.")

    if expected_total_seats !== nothing
        @assert total_seats == expected_total_seats "party_summary: expected $expected_total_seats seats, got $total_seats."
    end

    # Parties and coalitions are the same national accounting object. Keep the
    # established Float64 CSV view while sharing its exact scientific producer.
    quantities = [coalition_accounting_metrics(votes, seats;
        national_vote_total = total_votes, total_seats = total_seats)
        for (votes, seats) in zip(df[!, vote_col], df[!, seat_col])]
    df[!, :national_vote_total] = fill(total_votes, nrow(df))
    df[!, :vote_share] = [q.vote_share for q in quantities]
    df[!, :seat_share] = [q.seat_share for q in quantities]
    df[!, :quota] = [q.quota for q in quantities]
    df[!, :seat_diff] = [q.seat_diff for q in quantities]
    df[!, :representation_ratio] = Union{Missing,Float64}[q.representation_ratio for q in quantities]

    return df
end

function _majority_status(vote_majority::Bool, seat_majority::Bool)
    if vote_majority && seat_majority
        return "votes+seats"
    elseif seat_majority
        return "seats_only"
    elseif vote_majority
        return "votes_only"
    else
        return "neither"
    end
end

"""Proportional seat quota using integer votes and the full vote denominator."""
proportional_quota(votes::Integer, total_votes::Integer, total_seats::Integer) =
    (BigInt(total_seats) * BigInt(votes)) // BigInt(total_votes)

"""Exact national accounting shared by parties and every coalition domain.

Zero quota has an undefined representation ratio. A vote tie is never an
inversion, even when the coalition attains the actual seat-majority threshold.
"""
function exact_accounting(votes::Integer, seats::Integer;
    national_vote_total::Integer, total_seats::Integer = 513,
    seat_majority_threshold::Integer = fld(total_seats, 2) + 1,
)
    national_vote_total > 0 || error("National vote total must be positive.")
    total_seats > 0 || error("Chamber seat total must be positive.")
    seat_majority_threshold > 0 || error("Seat-majority threshold must be positive.")
    0 <= votes <= national_vote_total || error("Coalition votes are outside national totals.")
    0 <= seats <= total_seats || error("Coalition seats are outside Chamber totals.")
    q = proportional_quota(votes, national_vote_total, total_seats)
    d = BigInt(seats) - q
    r = BigInt(seat_majority_threshold) - q
    R = iszero(q) ? missing : BigInt(seats) / q
    vote_share = BigInt(votes) // BigInt(national_vote_total)
    seat_share = BigInt(seats) // BigInt(total_seats)
    vote_majority = 2 * BigInt(votes) > national_vote_total
    seat_majority = seats >= seat_majority_threshold
    inversion = seat_majority && 2 * BigInt(votes) < national_vote_total
    return (; q, d, r, R, vote_share, seat_share, vote_majority, seat_majority, inversion)
end

"""
    coalition_accounting_metrics(coalition_votes, coalition_seats;
                                 national_vote_total,
                                 total_seats=513,
                                 seat_majority_threshold=fld(total_seats, 2) + 1)

Return the common full-precision vote/seat accounting used for both observed
cabinet coalitions and contiguous ideological intervals. `required_diff` is the
absolute seat differential required for the proportional quota to reach the
Chamber-majority threshold. A zero-vote coalition has an undefined
`representation_ratio`, represented by `missing`.
"""
function coalition_accounting_metrics(
    coalition_votes::Integer,
    coalition_seats::Integer;
    national_vote_total::Integer,
    total_seats::Integer = 513,
    seat_majority_threshold::Integer = fld(total_seats, 2) + 1,
)
    exact = exact_accounting(coalition_votes, coalition_seats;
        national_vote_total, total_seats, seat_majority_threshold)
    # Preserve the established Float64 serialization order. These display views
    # do not classify coalitions or supply the exact decomposition arithmetic.
    votes = Float64(coalition_votes)
    seats = Float64(coalition_seats)
    national_votes = Float64(national_vote_total)
    chamber_seats = Float64(total_seats)
    majority_threshold = Int(seat_majority_threshold)

    vote_share = votes / national_votes
    seat_share = seats / chamber_seats
    quota = chamber_seats * vote_share
    seat_diff = seats - quota
    required_diff = majority_threshold - quota
    representation_ratio = quota > 0 ? seats / quota : missing
    vote_majority = exact.vote_majority
    seat_majority = exact.seat_majority

    return (
        national_vote_total = national_votes,
        vote_share = Float64(vote_share),
        seat_share = Float64(seat_share),
        quota = Float64(quota),
        seat_diff = Float64(seat_diff),
        required_diff = Float64(required_diff),
        representation_ratio = representation_ratio,
        vote_majority = Bool(vote_majority),
        seat_majority = Bool(seat_majority),
        majority_status = _majority_status(vote_majority, seat_majority),
        coalition_inversion = exact.inversion,
    )
end

"""Sum a membership set without changing the national vote denominator."""
function coalition_totals(df::DataFrame, parties;
    party_col::Symbol = :SG_PARTIDO, vote_col::Symbol = :valid_total,
    seat_col::Symbol = :total_seats,
)
    labels = String.(df[!, party_col])
    allunique(labels) || error("Party totals must have one row per party.")
    members = Set(String.(parties))
    absent = setdiff(members, Set(labels))
    isempty(absent) || error("Coalition party absent from election totals: $(join(sort(collect(absent)), ", "))")
    mask = in.(labels, Ref(members))
    return (votes = sum(df[mask, vote_col]), seats = sum(df[mask, seat_col]),
        national_vote_total = sum(df[!, vote_col]), total_seats = sum(df[!, seat_col]))
end

function _require_columns(df::DataFrame, cols::Vector{Symbol}, df_name::AbstractString)
    missing_cols = [col for col in cols if !(col in propertynames(df))]
    isempty(missing_cols) || error(
        "$(df_name) is missing required column(s): $(join(String.(missing_cols), ", ")).",
    )
    return nothing
end

function _duplicate_values(df::DataFrame, col::Symbol)
    counts = combine(groupby(DataFrame(value = String.(df[!, col])), :value), nrow => :n)
    return String.(counts.value[counts.n .> 1])
end

"""
    ideological_party_order(summary_df, ideology_df; universe=:seat_winning, tie_policy=:error)

Restrict the existing election order to the explicit ideological universe. The
primary universe contains exactly parties with observed positive Chamber seats;
`:all_parties` retains all election parties. Original ideological ranks are kept
in `original_ordinal_position`; `ordinal_position` and `ideological_index` are
consecutive positions in the selected universe. Ideological positions are never
estimated here. This helper does not define the national vote denominator.
"""
function ideological_party_order(
    summary_df::DataFrame,
    ideology_df::DataFrame;
    universe::Symbol = :seat_winning,
    tie_policy::Symbol = :error,
)
    universe in (:seat_winning, :all_parties) || error(
        "Unsupported ideological universe $(universe). Use :seat_winning or :all_parties.")
    tie_policy == :error || error("Unsupported tie_policy $(tie_policy). Only :error is implemented.")
    _require_columns(summary_df, [:SG_PARTIDO, :valid_total, :total_seats], "summary_df")
    _require_columns(ideology_df, [:SG_PARTIDO, :ordinal_position], "ideology_df")
    for (frame, name) in ((summary_df, "summary_df"), (ideology_df, "ideology_df"))
        duplicates = _duplicate_values(frame, :SG_PARTIDO)
        isempty(duplicates) || error("$(name) has duplicate SG_PARTIDO values: $(join(duplicates, ", ")).")
    end
    ideology_metadata = select(ideology_df, Not(intersect(propertynames(ideology_df),
        [:valid_total, :total_seats, :ideological_index, :ideological_universe])))
    ordered = innerjoin(ideology_metadata,
        select(summary_df, :SG_PARTIDO, :valid_total, :total_seats), on = :SG_PARTIDO,
    )
    summary_parties = sort(String.(summary_df.SG_PARTIDO))
    ordered_parties = sort(String.(ordered.SG_PARTIDO))
    summary_parties == ordered_parties || error(
        "Every party in summary_df must appear exactly once in ideology_df before ideological coalitions are meaningful. " *
        "Missing ideology coverage for: $(join(setdiff(summary_parties, ordered_parties), ", ")).")
    ordinal_counts = combine(groupby(ordered, :ordinal_position), nrow => :n)
    if any(ordinal_counts.n .> 1)
        duplicated_positions = ordinal_counts.ordinal_position[ordinal_counts.n .> 1]
        error("Duplicate ideology ordinal_position value(s) found: $(join(string.(duplicated_positions), ", ")). " *
              "Resolve tied ideological positions before ideological coalitions are meaningful; tied positions cannot be silently sorted by party name.")
    end
    all(ordered.valid_total .>= 0) || error("Party votes must be nonnegative.")
    all(ordered.total_seats .>= 0) || error("Party seats must be nonnegative.")
    all(isinteger, ordered.valid_total) || error("valid_total must be integer-valued for every party.")
    all(isinteger, ordered.total_seats) || error("total_seats must be integer-valued for every party.")
    sort!(ordered, :ordinal_position)
    full_order = String.(ordered.SG_PARTIDO)
    expected_parties = universe == :seat_winning ?
        String.(ordered.SG_PARTIDO[ordered.total_seats .> 0]) : full_order
    if universe == :seat_winning
        ordered = ordered[ordered.total_seats .> 0, :]
    end
    @assert String.(ordered.SG_PARTIDO) == expected_parties
    @assert issorted(indexin(String.(ordered.SG_PARTIDO), full_order))
    if !(:original_ordinal_position in propertynames(ordered))
        ordered[!, :original_ordinal_position] = copy(ordered.ordinal_position)
    end
    ordered[!, :ordinal_position] = collect(1:nrow(ordered))
    ordered[!, :ideological_index] = copy(ordered.ordinal_position)
    ordered[!, :ideological_universe] = fill(String(universe), nrow(ordered))
    return ordered
end

"""
    ideological_k_gap_coalitions(summary_df, ideology_df; k=0, universe=:seat_winning)

Enumerate D_0 or D_1 anew in the selected ideological universe. D_0 contains
complete connected intervals; D_1 additionally omits each single interior party.
Gaps count omitted members of this universe, and winning minimality is recomputed
against every admissible proper subset of the same D_k. Vote shares and quotas
always use all valid votes in `summary_df`, including zero-seat parties.
"""
function ideological_k_gap_coalitions(
    summary_df::DataFrame,
    ideology_df::DataFrame;
    k::Integer = 0,
    universe::Symbol = :seat_winning,
    tie_policy::Symbol = :error,
)
    k in (0, 1) || error("Unsupported ideological gap limit k=$(k). Only k=0 and k=1 are implemented.")
    ordered = ideological_party_order(summary_df, ideology_df; universe, tie_policy)
    parties = String.(ordered.SG_PARTIDO)
    votes = Int.(ordered.valid_total)
    seats = Int.(ordered.total_seats)
    # These totals deliberately come from P, not the filtered ideological order.
    total_votes = sum(Int.(summary_df.valid_total))
    total_seats = sum(Int.(summary_df.total_seats))
    total_votes > 0 || error("Total votes must be positive.")
    total_seats > 0 || error("Total seats must be positive.")
    @assert sum(seats) == total_seats
    seat_majority_threshold = fld(total_seats, 2) + 1
    n = nrow(ordered)
    rows = NamedTuple[]
    member_sets = BitSet[]
    seen_coalition_ids = Set{String}()
    for left_index in 1:n
        for right_index in left_index:n
            omission_indices = Int[0]
            if k == 1 && right_index >= left_index + 2
                append!(omission_indices, (left_index + 1):(right_index - 1))
            end
            for omitted_index in omission_indices
                member_indices = [index for index in left_index:right_index if index != omitted_index]
                member_parties = parties[member_indices]
                coalition_id = join(member_parties, "|")
                coalition_id in seen_coalition_ids && continue
                push!(seen_coalition_ids, coalition_id)
                push!(member_sets, BitSet(member_indices))
                coalition_votes = sum(votes[member_indices])
                coalition_seats = sum(seats[member_indices])
                accounting = coalition_accounting_metrics(coalition_votes, coalition_seats;
                    national_vote_total = total_votes, total_seats, seat_majority_threshold)
                inversion = accounting.coalition_inversion
                gap_count = right_index - left_index + 1 - length(member_indices)
                omitted_party = omitted_index == 0 ? missing : parties[omitted_index]
                coalition_label = omitted_index == 0 ?
                    "$(parties[left_index])--$(parties[right_index])" :
                    "$(parties[left_index])--$(parties[right_index]), omitting $(parties[omitted_index])"
                @assert universe != :seat_winning || all(seats[member_indices] .> 0)
                @assert universe != :seat_winning || omitted_index == 0 || seats[omitted_index] > 0
                push!(rows, (
                    ideological_universe = String(universe),
                    ideological_party_count = Int(n),
                    full_party_count = Int(nrow(summary_df)),
                    k = Int(k), coalition_id = coalition_id, coalition_label = coalition_label,
                    left_index = Int(left_index), right_index = Int(right_index),
                    left_original_ordinal_position = ordered.original_ordinal_position[left_index],
                    right_original_ordinal_position = ordered.original_ordinal_position[right_index],
                    left_endpoint = parties[left_index], right_endpoint = parties[right_index],
                    omitted_party = omitted_party, party_count = Int(length(member_indices)),
                    parties = join(member_parties, ", "), gap_count = Int(gap_count),
                    votes = Int(coalition_votes), national_vote_total = Int(total_votes),
                    vote_share = accounting.vote_share, seats = Int(coalition_seats),
                    total_seats = Int(total_seats), seat_majority_threshold = Int(seat_majority_threshold),
                    seat_share = accounting.seat_share, q_C = accounting.quota,
                    d_C = accounting.seat_diff, r_C = accounting.required_diff,
                    R_C = accounting.representation_ratio,
                    vote_majority = Bool(accounting.vote_majority),
                    seat_majority = Bool(accounting.seat_majority), inversion = Bool(inversion),
                    vote_deficit_pp = inversion ? 50.0 - 100.0 * accounting.vote_share : missing,
                ))
            end
        end
    end
    result = DataFrame(rows)
    expected_rows = n * (n + 1) ÷ 2 + (k == 1 ? binomial(n, 3) : 0)
    nrow(result) == expected_rows || error(
        "D_$(k) coalition count mismatch: expected $(expected_rows), found $(nrow(result)).")
    length(seen_coalition_ids) == nrow(result) || error("D_$(k) contains duplicate canonical party sets.")
    minimal_seat_majority = falses(nrow(result))
    winning_indices = findall(identity, Bool.(result.seat_majority))
    for coalition_index in winning_indices
        coalition_members = member_sets[coalition_index]
        has_winning_proper_subset = any(winning_indices) do subset_index
            subset_members = member_sets[subset_index]
            length(subset_members) < length(coalition_members) && issubset(subset_members, coalition_members)
        end
        minimal_seat_majority[coalition_index] = !has_winning_proper_subset
    end
    result[!, :minimal_seat_majority] = minimal_seat_majority
    result[!, :minimal_inversion] = result.inversion .& result.minimal_seat_majority
    sort!(result, [:left_index, :right_index, :gap_count, :omitted_party])
    return result
end

"""
    ideological_interval_coalitions(summary_df, ideology_df; universe=:seat_winning)

Exact-connected compatibility view of the shared D_0 enumeration, including
legacy plotting/accounting aliases. `minimal_inversion` is strictly below half
of all valid votes; `weak_inversion` retains a separate vote-tie diagnostic.
"""
function ideological_interval_coalitions(
    summary_df::DataFrame,
    ideology_df::DataFrame;
    universe::Symbol = :seat_winning,
    tie_policy::Symbol = :error,
)
    return ideological_interval_view(ideological_k_gap_coalitions(
        summary_df, ideology_df; k = 0, universe, tie_policy))
end

"""Presentation aliases for the already calculated exact-connected domain."""
function ideological_interval_view(domain::DataFrame)
    all(domain.k .== 0) || error("Interval view requires the k=0 domain.")
    result = copy(domain)
    for (alias, source) in ((:start_index, :left_index), (:end_index, :right_index),
        (:start_party, :left_endpoint), (:end_party, :right_endpoint),
        (:n_parties, :party_count), (:quota, :q_C), (:seat_diff, :d_C),
        (:required_diff, :r_C), (:representation_ratio, :R_C))
        result[!, alias] = copy(result[!, source])
    end
    result[!, :majority_status] = _majority_status.(result.vote_majority, result.seat_majority)
    result[!, :weak_inversion] = result.seat_majority .& .!result.vote_majority
    result[!, :strict_inversion] = copy(result.inversion)
    result[!, :vote_tie_seat_majority] = result.seat_majority .& (2 .* result.votes .== result.national_vote_total)
    result[!, :complement_votes] = result.national_vote_total .- result.votes
    result[!, :complement_vote_share] = result.complement_votes ./ result.national_vote_total
    result[!, :complement_seats] = result.total_seats .- result.seats
    result[!, :complement_seat_share] = result.complement_seats ./ result.total_seats
    return result
end


# =============================================================================
# Coalition periods (ministerial base)
# =============================================================================

function period_sort_key(period::AbstractString)
    parts = split(period, ".")
    if length(parts) == 2
        year = tryparse(Int, parts[1])
        idx = tryparse(Int, parts[2])
        if year !== nothing && idx !== nothing
            return (year, idx, period)
        end
    end
    return (typemax(Int), typemax(Int), period)
end

"""
    coalitions_by_period(; path=get_coalition_path())

Carrega `partidos_por_periodo.json` e retorna um Dict de periodo => partidos,
com siglas normalizadas por `canonical_party`.
"""
function coalitions_by_period(; path::AbstractString = get_coalition_path())
    return CabinetRelease.identified_parties(path)
end

function parse_coalition_date(value, period::AbstractString, field::AbstractString)
    if value === nothing || value === missing
        return nothing
    end
    s = strip(String(value))
    isempty(s) && return nothing
    d = tryparse(Date, s)
    d === nothing && error("parse_coalition_date: data inválida em $period.$field: '$s'")
    return d
end

function coalition_period_windows(; path::AbstractString = get_coalition_path())
    return CabinetRelease.period_windows(path)
end

"""
    coalition_periods_by_label_year(periods, year)

Seleciona períodos cuja chave começa com `YYYY.`. Esta é uma semântica de
rótulo do adaptador, mas não significa que os períodos selecionados sejam
todos os períodos ativos durante o ano civil. Períodos iniciados em anos
anteriores também podem sobrepor a janela consultada.
"""
function coalition_periods_by_label_year(periods::Dict{String,Vector{String}}, year::Integer)
    prefix = string(year) * "."
    period_keys = sort([k for k in keys(periods) if startswith(k, prefix)]; by = period_sort_key)
    return Dict(k => periods[k] for k in period_keys)
end

"""
    overlaps_window(period_start, period_end, window_start, window_end)

Retorna `true` quando dois intervalos fechados de datas se sobrepõem. A
semântica é inclusiva: um período se sobrepõe a uma janela se
`period_start <= window_end && period_end >= window_start`.
"""
function overlaps_window(period_start::Date, period_end::Date, window_start::Date, window_end::Date)
    return period_start <= window_end && period_end >= window_start
end

"""
    coalition_periods_overlapping_window(periods, window_start, window_end; path=get_coalition_path())

Seleciona os períodos de coalizão ativos em qualquer parte da janela fechada
`window_start` a `window_end`, usando as datas da versão histórica fixada.
O adaptador converte uma única vez o fim exclusivo para a interface inclusiva.
O rótulo (`YYYY.k`) indica o ano inicial, não todos os anos ativos. Uma janela
inteiramente não identificada retorna seleção vazia; seu calendário continua
explicitamente representado pela versão histórica.
"""
function coalition_periods_overlapping_window(periods::Dict{String,Vector{String}},
                                              window_start::Date,
                                              window_end::Date;
                                              path::AbstractString = get_coalition_path())
    window_end < window_start && error(
        "coalition_periods_overlapping_window: intervalo inválido ($window_start > $window_end).",
    )

    windows = coalition_period_windows(; path=path)

    selected = Pair{String,Vector{String}}[]
    bounds = Tuple{Date,Date}[]
    missing_dates = String[]

    for (period, parties) in periods
        if !haskey(windows, period)
            push!(missing_dates, period)
            continue
        end

        start_date, end_date = windows[period]
        if start_date === nothing || end_date === nothing
            push!(missing_dates, period)
            continue
        end
        end_date < start_date && error("coalition_periods_overlapping_window: intervalo inválido em $period ($start_date > $end_date).")

        push!(bounds, (start_date, end_date))
        if overlaps_window(start_date, end_date, window_start, window_end)
            push!(selected, period => parties)
        end
    end

    if !isempty(missing_dates)
        sample_vec = sort(unique(missing_dates))
        sample = isempty(sample_vec) ? "nenhum período com datas válidas" :
                 join(sample_vec[1:min(length(sample_vec), 5)], ", ")
        error("coalition_periods_overlapping_window: dados insuficientes para filtrar a janela $window_start a $window_end (faltam datas em: $sample).")
    end

    # An observed window can contain only explicitly unidentified cabinet sets.
    # Its identified-period selection is empty; the full release calendar still
    # records the dates and unknown status. Do not reinterpret this as a parser error.

    sort!(selected, by = p -> begin
        start_date, _ = windows[p.first]
        (start_date::Date, period_sort_key(p.first))
    end)
    return Dict(selected)
end

"""
    coalition_periods_overlapping_year(periods, year; path=get_coalition_path())

Seleciona, por sobreposição inclusiva de datas, todos os períodos ativos em
qualquer parte do ano civil `year`. Use esta função para análises por ano civil;
use `coalition_periods_by_label_year` apenas quando a pergunta for sobre o ano
codificado no rótulo da chave.
"""
function coalition_periods_overlapping_year(periods::Dict{String,Vector{String}}, year::Integer;
                                            path::AbstractString = get_coalition_path())
    return coalition_periods_overlapping_window(
        periods,
        Date(year, 1, 1),
        Date(year, 12, 31);
        path = path,
    )
end




"""Read the published election-space party sets from the pinned cabinet input."""
function coalitions_by_period_raw(; path::AbstractString = get_coalition_path())
    return CabinetRelease.identified_parties(path)
end
