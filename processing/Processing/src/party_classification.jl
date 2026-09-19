const _CLASSIFICATION_SUPPORTED_YEARS = (2023, 2025)
const _CLASSIFICATION_YEAR_LABELS = join(_CLASSIFICATION_SUPPORTED_YEARS, ", ")

_to_string_or_missing(x) = (x === missing || x === nothing) ? missing : String(x)

function _to_float_or_missing(x)::Union{Missing,Float64}
    if x === missing || x === nothing
        return missing
    elseif x isa Real
        return Float64(x)
    end

    raw = strip(String(x))
    isempty(raw) && return missing
    parsed = tryparse(Float64, replace(raw, "," => "."))
    return parsed === nothing ? missing : parsed
end

function _to_int_or_missing(x)::Union{Missing,Int}
    if x === missing || x === nothing
        return missing
    elseif x isa Integer
        return Int(x)
    elseif x isa AbstractFloat
        if isfinite(x) && trunc(x) == x
            return Int(x)
        end
        return missing
    end

    raw = strip(String(x))
    isempty(raw) && return missing
    parsed = tryparse(Int, raw)
    return parsed === nothing ? missing : parsed
end

function _processing_root_from(start_dir::AbstractString)::String
    current = abspath(start_dir)
    while true
        if isfile(joinpath(current, "Project.toml"))
            return current
        end
        parent = dirname(current)
        parent == current && error(
            "Não foi possível resolver o root do Processing a partir de $(abspath(start_dir)); nenhum Project.toml foi encontrado.",
        )
        current = parent
    end
end

_repo_root() = abspath(_processing_root_from(@__DIR__), "..", "..")

function _default_classification_root_dir()::String
    return joinpath(_repo_root(), "scrape_classification", "output")
end

function _default_party_alias_path()::String
    return abspath(joinpath(@__DIR__, "..", "data", "party_aliases.csv"))
end

function _classification_dir(year::Int, root_dir::AbstractString)::String
    return joinpath(abspath(String(root_dir)), "classificacao_$(year)")
end

function _pick_first_column(df::DataFrame, candidates::Vector{Symbol})::Union{Nothing,Symbol}
    for col in candidates
        hasproperty(df, col) && return col
    end
    return nothing
end

function _party_column(df::DataFrame)::Symbol
    col = _pick_first_column(df, [:party_name_raw, :party_raw, :Partido, :partido, :party, :SG_PARTIDO])
    col === nothing && error(
        "Classificação ideológica sem coluna de partido. Esperado um de: party_name_raw, party_raw, Partido, partido.",
    )
    return col
end

function _label_column(df::DataFrame)::Union{Nothing,Symbol}
    return _pick_first_column(df, [:classification_label, :ideologia_categorica, :classification, :label])
end

function _score_column(df::DataFrame)::Union{Nothing,Symbol}
    return _pick_first_column(df, [:ideology_value_numeric, :media_ponderada, :ideology_value, :score])
end

function _compute_ordinal_position_from_score(score_values)::Vector{Int}
    n = length(score_values)
    numeric = [_to_float_or_missing(x) for x in score_values]
    if any(ismissing, numeric)
        miss_idx = findfirst(ismissing, numeric)
        error("Classificação ideológica com score missing na posição $(miss_idx); impossível calcular ordinal_position.")
    end

    idx = collect(1:n)
    sort!(idx; by = i -> (numeric[i]::Float64, i))

    ordinal = Vector{Int}(undef, n)
    for (position, row_idx) in enumerate(idx)
        ordinal[row_idx] = position
    end
    return ordinal
end

function _ensure_ordinal_position!(df::DataFrame)
    if hasproperty(df, :ordinal_position)
        df[!, :ordinal_position] = [_to_int_or_missing(x) for x in df[!, :ordinal_position]]
        if any(ismissing, df[!, :ordinal_position])
            miss_idx = findfirst(ismissing, df[!, :ordinal_position])
            error("Coluna ordinal_position contém missing na linha $(miss_idx).")
        end
        df[!, :ordinal_position] = Int.(df[!, :ordinal_position])
        return df
    end

    score_col = _score_column(df)
    score_col === nothing && error(
        "Classificação ideológica sem ordinal_position e sem coluna de score equivalente (ideology_value_numeric/media_ponderada).",
    )
    df[!, :ordinal_position] = _compute_ordinal_position_from_score(df[!, score_col])
    return df
end

function _ensure_party_name_raw!(df::DataFrame)
    if hasproperty(df, :party_name_raw)
        df[!, :party_name_raw] = [_to_string_or_missing(x) for x in df[!, :party_name_raw]]
        return df
    end

    party_col = _party_column(df)
    df[!, :party_name_raw] = [_to_string_or_missing(x) for x in df[!, party_col]]
    return df
end

function _ensure_classification_label!(df::DataFrame)
    if hasproperty(df, :classification_label)
        df[!, :classification_label] = [_to_string_or_missing(x) for x in df[!, :classification_label]]
        return df
    end

    label_col = _label_column(df)
    label_col === nothing && error(
        "Classificação ideológica sem classification_label e sem coluna equivalente (ideologia_categorica).",
    )
    df[!, :classification_label] = [_to_string_or_missing(x) for x in df[!, label_col]]
    return df
end

function _ensure_ideology_value_numeric!(df::DataFrame)
    if hasproperty(df, :ideology_value_numeric)
        df[!, :ideology_value_numeric] = [_to_float_or_missing(x) for x in df[!, :ideology_value_numeric]]
        return df
    end

    score_col = _score_column(df)
    if score_col === nothing
        df[!, :ideology_value_numeric] = fill(missing, nrow(df))
    else
        df[!, :ideology_value_numeric] = [_to_float_or_missing(x) for x in df[!, score_col]]
    end
    return df
end

function _postprocess_loaded_classification!(df::DataFrame, year::Int)::DataFrame
    _ensure_party_name_raw!(df)
    _ensure_classification_label!(df)
    _ensure_ideology_value_numeric!(df)
    _ensure_ordinal_position!(df)
    df[!, :source_year] = fill(Int(year), nrow(df))
    sort!(df, :ordinal_position)
    return df
end

function _load_classification_2023(root_dir::AbstractString)::DataFrame
    base = _classification_dir(2023, root_dir)
    json_path = joinpath(base, "party_ordinal_classificacao.json")
    csv_path = joinpath(base, "party_ordinal_classificacao.csv")

    if isfile(json_path)
        return PartyClassification2023.load_party_ordinal_classification_2023(path = json_path)
    elseif isfile(csv_path)
        return CSV.read(csv_path, DataFrame)
    end

    error("classificacao_2023 não encontrada em $base (esperado JSON ou CSV).")
end

function _load_classification_2025(root_dir::AbstractString)::DataFrame
    base = _classification_dir(2025, root_dir)
    csv_path = joinpath(base, "party_classificacao_2025.csv")

    if !isfile(csv_path)
        csv_candidates = filter(path -> endswith(lowercase(path), ".csv"), readdir(base; join = true))
        isempty(csv_candidates) && error("classificacao_2025 sem CSV em $base.")
        csv_path = only(sort(csv_candidates))
    end

    return CSV.read(csv_path, DataFrame)
end

"""
    load_party_classification(year::Int; root_dir::AbstractString = _default_classification_root_dir())::DataFrame

Carrega classificação ideológica por ano-fonte.
- `year == 2023`: usa `classificacao_2023`
- `year == 2025`: usa `classificacao_2025`
"""
function load_party_classification(
    year::Int;
    root_dir::AbstractString = _default_classification_root_dir(),
)::DataFrame
    if year == 2023
        return _postprocess_loaded_classification!(_load_classification_2023(root_dir), year)
    elseif year == 2025
        return _postprocess_loaded_classification!(_load_classification_2025(root_dir), year)
    end

    error("Ano de classificação não suportado: $year. Suportados: $(_CLASSIFICATION_YEAR_LABELS).")
end

"""
    canonicalize_party_classification!(df; year::Int, strict::Bool=true)::DataFrame

Adiciona colunas de canonicalização:
- `party_raw` (texto bruto de partido da fonte)
- `party_norm` (normalização lexical)
- `party_canon` (chave canônica por ano)

Com `strict=true`, falha na primeira linha não mapeada e aponta a tabela de aliases.
"""
function canonicalize_party_classification!(
    df::DataFrame;
    year::Int,
    strict::Bool = true,
)::DataFrame
    party_col = _party_column(df)
    alias_path = _default_party_alias_path()

    party_raw = [strip(String(coalesce(x, ""))) for x in df[!, party_col]]
    df[!, :party_raw] = party_raw
    df[!, :party_norm] = normalize_party.(party_raw)

    canon = Vector{String}(undef, nrow(df))
    for i in eachindex(party_raw)
        raw = party_raw[i]
        if isempty(raw)
            if strict
                error("Classificação ideológica com party_raw vazio na linha $i. Edite: $alias_path")
            end
            canon[i] = UNKNOWN_PARTY
            continue
        end

        if strict
            try
                canon[i] = canonical_party(raw; year = Int(year), strict = true, alias_path = alias_path)
            catch err
                msg = sprint(showerror, err)
                error(
                    "Falha ao canonicalizar classificação ideológica (year=$year, linha=$i, party_raw='$raw'). " *
                    "Edite: $alias_path. Detalhe: $msg",
                )
            end
        else
            canon[i] = canonical_party(raw; year = Int(year), strict = false, alias_path = alias_path)
        end
    end

    df[!, :party_canon] = canon
    return df
end

"""
    classification_minimal(df)::DataFrame

Retorna somente as colunas mínimas para joins:
- `party_canon`
- `ordinal_position`
- `classification_label`
- `source_year`
"""
function classification_minimal(df::DataFrame)::DataFrame
    hasproperty(df, :party_canon) || error(
        "classification_minimal: coluna party_canon ausente. Rode canonicalize_party_classification! antes.",
    )

    _ensure_ordinal_position!(df)
    _ensure_classification_label!(df)
    hasproperty(df, :source_year) || error(
        "classification_minimal: coluna source_year ausente. Use load_party_classification(year).",
    )

    out = DataFrame(
        party_canon = String.(df[!, :party_canon]),
        ordinal_position = Int.(df[!, :ordinal_position]),
        classification_label = String.(coalesce.(df[!, :classification_label], "")),
        source_year = Int.(df[!, :source_year]),
    )
    sort!(out, :ordinal_position)
    return out
end

_period_year(period::AbstractString) = begin
    raw = strip(String(period))
    isempty(raw) && return nothing
    parsed = tryparse(Int, first(split(raw, ".")))
    return parsed === nothing ? nothing : Int(parsed)
end

function _main_source_parties(; strict::Bool=false)::Set{String}
    repo_root = _repo_root()
    parties = Set{String}()
    aliases = load_party_aliases(_default_party_alias_path())

    function _canonical(raw::AbstractString, year::Int)::String
        return _canonical_from_aliases(
            raw,
            aliases;
            year = year,
            strict = strict,
            alias_path = _default_party_alias_path(),
        )
    end

    for year in (2014, 2018, 2022)
        path = joinpath(repo_root, "data", "raw", "electionsBR", string(year), "party_mun_zone.csv")
        isfile(path) || continue
        file = CSV.File(path; select = (i, name) -> String(name) == "SG_PARTIDO")
        raw_parties = Set{String}()
        for row in file
            raw = strip(String(row.SG_PARTIDO))
            isempty(raw) && continue
            push!(raw_parties, raw)
        end
        for raw in raw_parties
            canon = _canonical(raw, year)
            canon == UNKNOWN_PARTY && continue
            push!(parties, canon)
        end
    end

    # Ideological coverage is assessed against frozen election-party inputs.
    # Cabinet identities are independently checked by the pinned release adapter.

    return parties
end

function party_classification_audit(
    df::DataFrame;
    year::Int,
)::DataFrame
    hasproperty(df, :party_raw) || error("party_classification_audit: rode canonicalize_party_classification! antes.")
    hasproperty(df, :party_norm) || error("party_classification_audit: coluna party_norm ausente.")
    hasproperty(df, :party_canon) || error("party_classification_audit: coluna party_canon ausente.")

    _ensure_ordinal_position!(df)
    _ensure_classification_label!(df)
    _ensure_ideology_value_numeric!(df)

    rows = NamedTuple[]

    # unknown aliases
    unknown_mask = df[!, :party_canon] .== UNKNOWN_PARTY
    for row in eachrow(df[unknown_mask, :])
        push!(rows, (
            audit_type = "unknown",
            source_year = Int(year),
            party_raw = String(row.party_raw),
            party_norm = String(row.party_norm),
            party_canon = String(row.party_canon),
            ordinal_position = Int(row.ordinal_position),
            classification_label = String(coalesce(row.classification_label, "")),
            ideology_value_numeric = _to_float_or_missing(row.ideology_value_numeric),
            detail = "Alias não mapeado; revisar party_aliases.csv",
            count = missing,
        ))
    end

    # duplicated canonical keys and potential conflicts
    grouped = groupby(df, :party_canon)
    duplicate_total = 0
    conflict_total = 0
    for g in grouped
        canon = String(g.party_canon[1])
        canon == UNKNOWN_PARTY && continue
        n = nrow(g)
        n <= 1 && continue
        duplicate_total += 1

        n_ord = length(unique(Int.(g.ordinal_position)))
        n_label = length(unique(String.(coalesce.(g.classification_label, ""))))
        n_score = length(unique(skipmissing(_to_float_or_missing.(g.ideology_value_numeric))))

        has_conflict = (n_ord > 1 || n_label > 1 || n_score > 1)
        has_conflict && (conflict_total += 1)
        detail = has_conflict ? "duplicate_conflict" : "duplicate_same_values"

        push!(rows, (
            audit_type = "duplicate",
            source_year = Int(year),
            party_raw = missing,
            party_norm = missing,
            party_canon = canon,
            ordinal_position = missing,
            classification_label = missing,
            ideology_value_numeric = missing,
            detail = detail,
            count = n,
        ))
    end
    push!(rows, (
        audit_type = "duplicates_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "duplicate_party_canon_groups",
        count = duplicate_total,
    ))
    push!(rows, (
        audit_type = "duplicates_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "duplicate_conflict_groups",
        count = conflict_total,
    ))

    # simple coverage against main sources (TSE + coalition CSV)
    main_parties = _main_source_parties(; strict = false)
    class_parties = Set(
        String(p) for p in df.party_canon if p != UNKNOWN_PARTY && !isempty(strip(String(p)))
    )

    coverage_intersection = intersect(class_parties, main_parties)
    coverage_missing = setdiff(class_parties, main_parties)

    push!(rows, (
        audit_type = "coverage_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "classification_unique_parties",
        count = length(class_parties),
    ))
    push!(rows, (
        audit_type = "coverage_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "main_sources_unique_parties",
        count = length(main_parties),
    ))
    push!(rows, (
        audit_type = "coverage_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "intersection_unique_parties",
        count = length(coverage_intersection),
    ))
    push!(rows, (
        audit_type = "coverage_summary",
        source_year = Int(year),
        party_raw = missing,
        party_norm = missing,
        party_canon = missing,
        ordinal_position = missing,
        classification_label = missing,
        ideology_value_numeric = missing,
        detail = "missing_in_main_sources",
        count = length(coverage_missing),
    ))

    for canon in sort(collect(coverage_missing))
        push!(rows, (
            audit_type = "coverage_missing",
            source_year = Int(year),
            party_raw = missing,
            party_norm = missing,
            party_canon = canon,
            ordinal_position = missing,
            classification_label = missing,
            ideology_value_numeric = missing,
            detail = "party_canon não encontrado em fontes principais",
            count = missing,
        ))
    end

    return DataFrame(rows)
end

function write_party_classification_audit(
    df::DataFrame;
    year::Int,
    out_dir::AbstractString = joinpath(
        _processing_root_from(@__DIR__),
        "exploratory",
        "out",
        "party_classification_$(year)_audit",
    ),
)::String
    audit = party_classification_audit(df; year = year)
    mkpath(out_dir)
    out_path = joinpath(out_dir, "party_classification_audit.csv")
    CSV.write(out_path, audit)
    return out_path
end
