module PartyClassification2023

using DataFrames
using JSON3

export load_party_ordinal_classification_2023,
       party_classification_full,
       party_classification_simple,
       party_classification_simple_ideology,
       party_classification_simple_source

const _MINIMUM_COLUMNS = (:party_name_raw, :ordinal_position, :classification_label)
const _SIMPLE_COLUMNS = [:party_name_raw, :ordinal_position, :classification_label]
const _SIMPLE_IDEOLOGY_COLUMNS = [:party_name_raw, :ordinal_position, :classification_label, :ideology_value_numeric]
const _SIMPLE_SOURCE_COLUMNS = [:party_name_raw, :ordinal_position, :classification_label, :pdf_filename, :page_number, :classification_source, :scale_rule_reference]

function _project_root_from(start_dir::AbstractString)::String
    current = abspath(start_dir)
    while true
        if isfile(joinpath(current, "Project.toml"))
            return current
        end
        parent = dirname(current)
        parent == current && error(
            "Não foi possível resolver o root do projeto a partir de $(abspath(start_dir)); nenhum Project.toml foi encontrado.",
        )
        current = parent
    end
end

function _default_json_path()::String
    project_root = _project_root_from(@__DIR__)
    return abspath(
        project_root,
        "..",
        "..",
        "scrape_classification",
        "output",
        "classificacao_2023",
        "party_ordinal_classificacao.json",
    )
end

_resolve_json_path(path::Nothing)::String = _default_json_path()

function _resolve_json_path(path::String)::String
    project_root = _project_root_from(@__DIR__)
    return isabspath(path) ? path : abspath(project_root, path)
end

function _normalize_json_value(value)
    if value === nothing
        return missing
    elseif value isa AbstractString
        return String(value)
    end
    return value
end

function _json_rows_to_dicts(payload)
    payload isa AbstractVector || error("JSON inválido: esperado array de objetos.")

    rows = Vector{Dict{Symbol,Any}}(undef, length(payload))
    for (index, item) in pairs(payload)
        if !(item isa AbstractDict || item isa JSON3.Object)
            error("JSON inválido: item na posição $index não é objeto.")
        end
        rows[index] = Dict{Symbol,Any}(
            Symbol(String(key)) => _normalize_json_value(value) for (key, value) in pairs(item)
        )
    end
    return rows
end

function _validate_minimum_columns(df::DataFrame)
    present = Set(Symbol.(names(df)))
    missing_cols = [col for col in _MINIMUM_COLUMNS if !(col in present)]
    isempty(missing_cols) || error(
        "Colunas mínimas ausentes no JSON: $(join(string.(missing_cols), ", ")).",
    )
    return nothing
end

function _ensure_column!(df::DataFrame, col::Symbol)
    if !hasproperty(df, col)
        df[!, col] = fill(missing, nrow(df))
    end
    return df
end

function _to_required_int(value, col::Symbol)::Int
    if value === missing || value === nothing
        error("Coluna $col contém valor missing/nothing, mas o tipo esperado é Int.")
    elseif value isa Integer
        return Int(value)
    elseif value isa AbstractFloat
        isfinite(value) || error("Coluna $col contém valor não finito: $value")
        trunc(value) == value || error("Coluna $col contém valor não inteiro: $value")
        return Int(value)
    elseif value isa AbstractString
        parsed = tryparse(Int, strip(String(value)))
        parsed === nothing && error("Coluna $col contém valor não inteiro: $(repr(value))")
        return parsed
    end
    error("Coluna $col contém tipo não suportado: $(typeof(value))")
end

function _to_float_or_missing(value)::Union{Missing,Float64}
    if value === missing || value === nothing
        return missing
    elseif value isa Real
        return Float64(value)
    end
    return missing
end

function _to_int_or_missing(value)::Union{Missing,Int}
    if value === missing || value === nothing
        return missing
    elseif value isa Integer
        return Int(value)
    elseif value isa AbstractFloat
        if isfinite(value) && trunc(value) == value
            return Int(value)
        end
        return missing
    elseif value isa AbstractString
        raw = strip(String(value))
        isempty(raw) && return missing
        parsed = tryparse(Int, raw)
        return parsed === nothing ? missing : parsed
    end
    return missing
end

function _normalize_string_values!(df::DataFrame)
    for col in names(df)
        values = df[!, col]
        if any(x -> x isa AbstractString, values)
            df[!, col] = [x isa AbstractString ? String(x) : x for x in values]
        end
    end
    return df
end

function _normalize_types!(df::DataFrame)
    df[!, :ordinal_position] = [_to_required_int(x, :ordinal_position) for x in df[!, :ordinal_position]]

    _ensure_column!(df, :ideology_value_numeric)
    _ensure_column!(df, :page_number)

    df[!, :ideology_value_numeric] = [_to_float_or_missing(x) for x in df[!, :ideology_value_numeric]]
    df[!, :page_number] = [_to_int_or_missing(x) for x in df[!, :page_number]]
    return df
end

function _sorted(df::DataFrame)::DataFrame
    return sort(df, :ordinal_position)
end

function _select_columns(df::DataFrame, cols::Vector{Symbol})::DataFrame
    out = copy(df)
    for col in cols
        _ensure_column!(out, col)
    end
    return _sorted(select(out, cols))
end

"""
    load_party_ordinal_classification_2023(; path::Union{Nothing,String}=nothing)::DataFrame

Carrega a classificação ordinal de partidos de 2023 em DataFrame.
Quando `path` é `nothing`, usa o caminho padrão relativo ao root do projeto.
"""
function load_party_ordinal_classification_2023(; path::Union{Nothing,String}=nothing)::DataFrame
    resolved_path = _resolve_json_path(path)
    if !isfile(resolved_path)
        error("Arquivo JSON não encontrado. Caminho esperado: $resolved_path")
    end

    payload = open(resolved_path, "r") do io
        JSON3.read(io)
    end

    rows = _json_rows_to_dicts(payload)
    df = DataFrame(rows)

    _validate_minimum_columns(df)
    _normalize_string_values!(df)
    _normalize_types!(df)

    return _sorted(df)
end

party_classification_full(; kwargs...) = load_party_ordinal_classification_2023(; kwargs...)

function party_classification_simple(; kwargs...)::DataFrame
    df = load_party_ordinal_classification_2023(; kwargs...)
    return _select_columns(df, _SIMPLE_COLUMNS)
end

function party_classification_simple_ideology(; kwargs...)::DataFrame
    df = load_party_ordinal_classification_2023(; kwargs...)
    return _select_columns(df, _SIMPLE_IDEOLOGY_COLUMNS)
end

function party_classification_simple_source(; kwargs...)::DataFrame
    df = load_party_ordinal_classification_2023(; kwargs...)
    return _select_columns(df, _SIMPLE_SOURCE_COLUMNS)
end

end
