"""Thin Julia view of the shared public cabinet-contract loader."""
module CabinetRelease
using DataFrames, Dates, JSON3
export calendar_table, identified_parties, period_windows, validate_parties, default_pin_path
const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
# The argument is the public metadata file, retained in the existing path API.
default_pin_path() = joinpath(ROOT, "data", "cabinet", "metadata.json")
const CACHE = Dict{String,DataFrame}()
function calendar_table(path::AbstractString=default_pin_path())
    abspath(path) == default_pin_path() || error("Cabinet input error: use the explicit local data/cabinet snapshot")
    haskey(CACHE,path) && return copy(CACHE[path])
    python = get(ENV,"PYTHON_BIN",get(ENV,"PYTHON","python3"))
    loader = joinpath(ROOT,"processing","cabinet_contract.py")
    # One contract implementation across languages. A failed check propagates;
    # neither a generated table nor any historical input can substitute for it.
    published = JSON3.read(read(`$python -B $loader calendar`,String))
    rows = NamedTuple[]
    for r in published
        start=Date(String(r.start_inclusive)); stop=Date(String(r.end_exclusive))
        push!(rows,(; election_year=Int(r.election_year),period=String(r.period),
            period_id=String(r.analytical_period_id),source_periods=JSON3.write([String(r.analytical_period_id)]),
            administration_id=String(r.administration),start_inclusive=start,end_exclusive=stop,days=Int(r.days),
            period_start=start,period_end=stop-Day(1),period_days=Int(r.days),
            composition_status=String(r.historical_status),election_party_set=String(r.election_party_set),
            established_days=Int(r.established_days),provisional_days=Int(r.provisional_days),identified=true))
    end
    CACHE[path]=DataFrame(rows)
    return copy(CACHE[path])
end
function identified_parties(path::AbstractString=default_pin_path())
    Dict(String(r.period)=>String.(filter(!isempty,split(String(r.election_party_set),';'))) for r in eachrow(calendar_table(path)))
end
function period_windows(path::AbstractString=default_pin_path())
    Dict{String,Tuple{Union{Date,Nothing},Union{Date,Nothing}}}(String(r.period)=>(r.period_start,r.period_end) for r in eachrow(calendar_table(path)))
end
function validate_parties(parties; election_year,valid_election_parties)
    members=sort(unique(String.(parties)))
    absent=setdiff(members,Set(String.(valid_election_parties)))
    isempty(absent) || error("Cabinet input error: published election labels absent from $election_year electoral input: $absent")
    return members
end
end
