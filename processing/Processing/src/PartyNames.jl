const UNKNOWN_PARTY = "__UNKNOWN__"

_party_alias_path() = abspath(joinpath(@__DIR__, "..", "data", "party_aliases.csv"))
_party_lineage_events_path() = abspath(joinpath(@__DIR__, "..", "data", "party_lineage_events.csv"))

_to_year_or_nothing(x)::Union{Nothing,Int} = begin
    if x === missing || x === nothing
        nothing
    elseif x isa Integer
        Int(x)
    else
        raw = strip(String(x))
        isempty(raw) ? nothing : tryparse(Int, raw)
    end
end

_year_in_window(year::Int, lo::Union{Nothing,Int}, hi::Union{Nothing,Int}) = begin
    lo !== nothing && year < lo && return false
    hi !== nothing && year > hi && return false
    true
end

_to_date_or_nothing(x)::Union{Nothing,Date} = begin
    if x === missing || x === nothing
        nothing
    elseif x isa Date
        x
    else
        raw = strip(String(x))
        isempty(raw) ? nothing : tryparse(Date, raw)
    end
end

"""
    load_party_aliases(path::AbstractString = _party_alias_path()) -> DataFrame

Carrega a tabela única de aliases de partido.
Cada linha diz: alias normalizado -> nome canônico, com janela opcional de anos.
"""
function load_party_aliases(path::AbstractString = _party_alias_path())::DataFrame
    isfile(path) || error("Tabela de aliases não encontrada: $path")
    df = CSV.read(path, DataFrame)

    for col in (:alias_norm, :canonical, :valid_from_year, :valid_to_year)
        hasproperty(df, col) || error("Tabela de aliases sem coluna obrigatória: $col")
    end

    if !hasproperty(df, :notes)
        df[!, :notes] = fill("", nrow(df))
    end

    df[!, :alias_norm] = normalize_party.(String.(coalesce.(df.alias_norm, "")))
    df[!, :canonical] = strip.(String.(coalesce.(df.canonical, "")))
    df[!, :valid_from_year] = [_to_year_or_nothing(x) for x in df.valid_from_year]
    df[!, :valid_to_year] = [_to_year_or_nothing(x) for x in df.valid_to_year]
    df[!, :notes] = String.(coalesce.(df.notes, ""))

    filter!(row -> !isempty(row.alias_norm) && !isempty(row.canonical), df)
    return df
end

"""
    load_party_lineage_events(path = _party_lineage_events_path()) -> DataFrame

Loads organizational lineage history for audits and other date-aware consumers.
These events never mutate a frozen cabinet appointment origin; cabinet electoral
translation uses the separate cabinet-to-election crosswalk.
"""
function load_party_lineage_events(path::AbstractString = _party_lineage_events_path())::DataFrame
    isfile(path) || error("Tabela de eventos de linhagem partidária não encontrada: $path")
    df = CSV.read(path, DataFrame)

    for col in (:event_date, :effective_start, :event_type, :successor_party, :predecessor_party)
        hasproperty(df, col) || error("Tabela de eventos de linhagem sem coluna obrigatória: $col")
    end

    if !hasproperty(df, :effective_end)
        df[!, :effective_end] = fill(missing, nrow(df))
    end
    if !hasproperty(df, :notes)
        df[!, :notes] = fill("", nrow(df))
    end

    df[!, :event_date] = [_to_date_or_nothing(x) for x in df.event_date]
    df[!, :effective_start] = [_to_date_or_nothing(x) for x in df.effective_start]
    df[!, :effective_end] = [_to_date_or_nothing(x) for x in df.effective_end]
    df[!, :event_type] = lowercase.(strip.(String.(coalesce.(df.event_type, ""))))
    df[!, :successor_party] = strip.(String.(coalesce.(df.successor_party, "")))
    df[!, :predecessor_party] = strip.(String.(coalesce.(df.predecessor_party, "")))
    df[!, :successor_party_norm] = normalize_party.(df.successor_party)
    df[!, :predecessor_party_norm] = normalize_party.(df.predecessor_party)
    df[!, :notes] = String.(coalesce.(df.notes, ""))

    filter!(
        row -> row.event_date !== nothing &&
               row.effective_start !== nothing &&
               !isempty(row.event_type) &&
               !isempty(row.successor_party_norm) &&
               !isempty(row.predecessor_party_norm),
        df,
    )
    return df
end

"""
    normalize_party(s::AbstractString)::String

Normalização lexical mínima para comparar aliases entre fontes.

Regra: remove acento e pontuação, põe em maiúsculas e colapsa espaços.
Isso não decide identidade política; só padroniza texto para lookup.
"""
function normalize_party(s::AbstractString)::String
    text = strip(String(s))
    isempty(text) && return ""

    text = Unicode.normalize(text; stripmark = true)
    text = uppercase(text)
    text = replace(text, "_" => " ")
    text = replace(text, r"[^A-Z0-9 ]+" => " ")
    text = replace(text, r"\s+" => " ")
    return strip(text)
end

function _canonical_from_aliases(
    raw::AbstractString,
    aliases::DataFrame;
    year::Union{Int,Missing}=missing,
    strict::Bool=true,
    alias_path::AbstractString=_party_alias_path(),
)::String
    raw_str = strip(String(raw))
    norm = normalize_party(raw_str)

    candidates = aliases.canonical[aliases.alias_norm .== norm]

    if year !== missing
        y = Int(year)
        mask = [
            aliases.alias_norm[i] == norm &&
            _year_in_window(y, aliases.valid_from_year[i], aliases.valid_to_year[i])
            for i in eachindex(aliases.alias_norm)
        ]
        year_candidates = aliases.canonical[mask]
        if !isempty(year_candidates)
            candidates = year_candidates
        end
    end

    unique_candidates = sort(unique(String.(candidates)))

    if length(unique_candidates) == 1
        return only(unique_candidates)
    end

    if !strict
        return UNKNOWN_PARTY
    end

    year_token = year === missing ? "missing" : string(Int(year))
    if isempty(unique_candidates)
        error("Alias sem mapeamento: raw='$raw_str', norm='$norm', year=$year_token. Edite: $alias_path")
    end
    error(
        "Alias ambíguo: raw='$raw_str', norm='$norm', year=$year_token, " *
        "candidates=$(join(unique_candidates, "|")) . Edite: $alias_path",
    )
end

function _canonical_from_aliases_strict_year(
    raw::AbstractString,
    aliases::DataFrame,
    year::Int;
    strict::Bool=true,
    alias_path::AbstractString=_party_alias_path(),
)::String
    raw_str = strip(String(raw))
    norm = normalize_party(raw_str)

    mask = [
        aliases.alias_norm[i] == norm &&
        _year_in_window(year, aliases.valid_from_year[i], aliases.valid_to_year[i])
        for i in eachindex(aliases.alias_norm)
    ]
    unique_candidates = sort(unique(String.(aliases.canonical[mask])))

    if length(unique_candidates) == 1
        return only(unique_candidates)
    end
    if !strict
        return isempty(unique_candidates) ? UNKNOWN_PARTY : first(unique_candidates)
    end
    if isempty(unique_candidates)
        error("Alias sem mapeamento temporal: raw='$raw_str', norm='$norm', year=$year. Edite: $alias_path")
    end
    error(
        "Alias temporal ambíguo: raw='$raw_str', norm='$norm', year=$year, " *
        "candidates=$(join(unique_candidates, "|")) . Edite: $alias_path",
    )
end

function _lineage_event_active(row, d::Date)::Bool
    row.effective_start !== nothing && d < row.effective_start && return false
    row.effective_end !== nothing && d > row.effective_end && return false
    return true
end

"""
    canonical_party_at_date(raw_party, d; strict=true)

Canonicalizes a party label in contemporaneous cabinet-party space.

This is a calendar-time function for cabinet-period construction. It first
applies lexical aliases and ordinary one-to-one renames valid at `d`, then
applies dated lineage events. Fusion successors determine whether the cabinet
party set changed. Election-space expansion, such as `UNIÃO -> DEM + PSL` for
the 2018 Chamber delegation, belongs in the cabinet-to-election crosswalk.
"""
function canonical_party_at_date(
    raw_party::AbstractString,
    d::Date;
    strict::Bool=true,
    alias_path::AbstractString=_party_alias_path(),
    lineage_path::AbstractString=_party_lineage_events_path(),
)::String
    aliases = load_party_aliases(alias_path)
    lineage = load_party_lineage_events(lineage_path)
    party = _canonical_from_aliases_strict_year(raw_party, aliases, Dates.year(d); strict = strict, alias_path = alias_path)
    party == UNKNOWN_PARTY && return party

    party_norm = normalize_party(party)
    for row in eachrow(lineage)
        row.event_type == "fusion" || continue
        _lineage_event_active(row, d) || continue
        if party_norm == row.predecessor_party_norm
            return _canonical_from_aliases_strict_year(
                row.successor_party,
                aliases,
                Dates.year(d);
                strict = strict,
                alias_path = alias_path,
            )
        end
    end
    return party
end

"""
    canonical_party(raw::AbstractString; year::Union{Int,Missing}=missing, strict::Bool=true)::String

Resolve um alias bruto para o rótulo canônico usado nos joins do projeto.

- Primeiro aplica `normalize_party`.
- Depois busca na tabela `party_aliases.csv`.
- Se houver `year`, aplica a janela `[valid_from_year, valid_to_year]`.

Com `strict=true`, alias desconhecido/ambíguo lança erro curto com o caminho da tabela.
Com `strict=false`, retorna `"__UNKNOWN__"`.
"""
function canonical_party(
    raw::AbstractString;
    year::Union{Int,Missing}=missing,
    strict::Bool=true,
    alias_path::AbstractString=_party_alias_path(),
)::String
    aliases = load_party_aliases(alias_path)
    return _canonical_from_aliases(raw, aliases; year = year, strict = strict, alias_path = alias_path)
end

"""
    canonicalize_parties(raws::AbstractVector{<:AbstractString}; year::Union{Int,Missing}=missing, strict::Bool=true)

Canonicaliza um vetor de aliases e devolve nomes canônicos únicos ordenados.

Use `with_mapping=true` para também devolver uma tabela (raw, norm, canonical)
que facilita auditoria manual no REPL.
"""
function canonicalize_parties(
    raws::AbstractVector{<:AbstractString};
    year::Union{Int,Missing}=missing,
    strict::Bool=true,
    alias_path::AbstractString=_party_alias_path(),
    with_mapping::Bool=false,
)
    aliases = load_party_aliases(alias_path)
    mapped = String[]
    map_rows = NamedTuple[]

    for raw in raws
        canonical = _canonical_from_aliases(raw, aliases; year = year, strict = strict, alias_path = alias_path)
        push!(mapped, canonical)
        push!(map_rows, (
            alias_raw = String(raw),
            alias_norm = normalize_party(raw),
            canonical = canonical,
            year = year === missing ? missing : Int(year),
        ))
    end

    canonicals = sort(unique(mapped))
    return with_mapping ? (canonicals = canonicals, mapping = DataFrame(map_rows)) : canonicals
end

"""Canonical spelling of a verified appointment origin, without lineage changes."""
function canonical_appointment_party(raw; alias_path = _party_alias_path())
    token = normalize_party(String(raw))
    aliases = load_party_aliases(alias_path)
    canonical_labels = unique(String.(aliases.canonical))
    exact = [p for p in canonical_labels if normalize_party(p) == token]
    length(exact) == 1 && return only(exact)
    candidates = unique(String.(aliases.canonical[aliases.alias_norm .== token]))
    length(candidates) == 1 || error("Ambiguous/unknown appointment-party spelling: $(raw)")
    return only(candidates)
end
