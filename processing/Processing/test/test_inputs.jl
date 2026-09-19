using Test, CSV, DataFrames

@testset "Frozen election identities and ideology inputs" begin
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    for year in (2014, 2018, 2022)
        expected = sort(readlines(joinpath(@__DIR__, "fixtures", "canonical_set_election_$(year).txt")))
        raw = CSV.read(joinpath(root, "data/raw/electionsBR", string(year), "party_mun_zone.csv"), DataFrame;
            select=["DS_CARGO", "SG_PARTIDO"])
        federal = uppercase.(strip.(String.(raw.DS_CARGO))) .== "DEPUTADO FEDERAL"
        actual = Processing.canonicalize_parties(unique(String.(raw.SG_PARTIDO[federal])); year, strict=true)
        @test actual == expected
        @test allunique(expected)
    end
    @test_throws ErrorException Processing.load_party_classification(1999)
    mktempdir() do missing_root
        @test_throws ErrorException Processing.load_party_classification(2023; root_dir=missing_root)
    end
    for year in (2023, 2025)
        data = Processing.load_party_classification(year)
        @test !isempty(data)
        @test all(data.source_year .== year)
        @test eltype(data.ordinal_position) == Int
        Processing.canonicalize_party_classification!(data; year, strict=true)
        minimal = Processing.classification_minimal(data)
        @test issorted(minimal.ordinal_position)
        @test allunique(minimal.party_canon)
        @test allunique(minimal.ordinal_position)
        @test nrow(minimal) == nrow(data)
        @test Set(names(minimal)) == Set(["party_canon", "ordinal_position", "classification_label", "source_year"])
    end
    toy = DataFrame(Partido=["PARTIDO_INEXISTENTE"], media_ponderada=[5.0], ideologia_categorica=["centro"])
    @test_throws ErrorException Processing.canonicalize_party_classification!(copy(toy); year=2025, strict=true)
    Processing.canonicalize_party_classification!(toy; year=2025, strict=false)
    @test only(toy.party_canon) == Processing.UNKNOWN_PARTY
    @test Processing.canonicalize_parties([" PT ", "PT", "PMDB"]; year=2014, strict=true) == ["PMDB", "PT"]
        @testset "Aliases históricos exigem year no modo estrito" begin
            @test_throws ErrorException Processing.canonical_party("PMDB")
            @test_throws ErrorException Processing.canonical_party("PR")
            @test_throws ErrorException Processing.canonical_party("PRB")
            @test_throws ErrorException Processing.canonical_party("PPS")
            @test_throws ErrorException Processing.canonical_party("PEN")
            @test_throws ErrorException Processing.canonical_party("PTN")
            @test_throws ErrorException Processing.canonical_party("PT do B")
        end

        @testset "Casos críticos conhecidos" begin
            @test Processing.canonical_party("PMDB"; year = 2014) == "PMDB"
            @test Processing.canonical_party("PMDB"; year = 2022) == "MDB"

            @test Processing.canonical_party("PC do B"; year = 2014) == "PCdoB"
            @test Processing.canonical_party("PCdoB"; year = 2022) == "PCdoB"

            @test Processing.canonical_party("PRB"; year = 2018) == "PRB"
            @test Processing.canonical_party("PRB"; year = 2022) == "REPUBLICANOS"
            @test Processing.canonical_party("REPU"; year = 2022) == "REPUBLICANOS"
            @test Processing.canonical_party("REP"; year = 2022) == "REPUBLICANOS"

            @test Processing.canonical_party("PEN"; year = 2014) == "PEN"
            @test Processing.canonical_party("PEN"; year = 2022) == "PATRIOTA"
            @test Processing.canonical_party("PATRI"; year = 2018) == "PATRIOTA"

            @test Processing.canonical_party("PPS"; year = 2018) == "PPS"
            @test Processing.canonical_party("PPS"; year = 2022) == "CIDADANIA"

            @test Processing.canonical_party("UNIAO"; year = 2022) == "UNIÃO"
            @test Processing.canonical_party("UNIÃO"; year = 2022) == "UNIÃO"
        end

end

using Test
using CSV
using DataFrames
using Dates

const _ROOT_DIR_PSC = abspath(@__DIR__, "..", "..", "..")
const _CANDIDATE_2018_PSC = joinpath(
    _ROOT_DIR_PSC,
    "data",
    "raw",
    "electionsBR",
    "2018",
    "candidate.csv",
)

@testset "Frozen 2018 seat input and accepted result snapshot" begin
    needed = [
        :SQ_CANDIDATO,
        :SG_UF,
        :DS_CARGO,
        :NM_CANDIDATO,
        :NM_URNA_CANDIDATO,
        :SG_PARTIDO,
        :DS_SITUACAO_CANDIDATURA,
        :DS_SIT_TOT_TURNO,
    ]
    candidates = CSV.read(
        _CANDIDATE_2018_PSC,
        DataFrame;
        select = needed,
        normalizenames = true,
        types = Dict(:SQ_CANDIDATO => String),
    )
    filter!(
        row -> uppercase(strip(String(row.DS_CARGO))) == "DEPUTADO FEDERAL",
        candidates,
    )
    statuses = uppercase.(strip.(String.(candidates.DS_SIT_TOT_TURNO)))
    counted = in.(statuses, Ref(Processing.WINNER_STATUSES))
    candidates[!, :current_loader_counts] = counted

    @test Set(statuses) == Set([
        "#NULO#",
        "ELEITO POR MÉDIA",
        "ELEITO POR QP",
        "NÃO ELEITO",
        "SUPLENTE",
    ])
    @test count(counted) == 513
    @test length(unique(candidates.SQ_CANDIDATO[counted])) == 513

    elected = candidates[counted, :]
    elected[!, :canonical_party] = [
        Processing.canonical_party(String(raw); year = 2018)
        for raw in elected.SG_PARTIDO
    ]
    raw_seats = combine(groupby(elected, :SG_PARTIDO), nrow => :seats)
    canonical_seats = combine(groupby(elected, :canonical_party), nrow => :seats)
    @test sum(raw_seats.seats) == 513
    @test sum(canonical_seats.seats) == 513
    @test only(raw_seats.seats[raw_seats.SG_PARTIDO .== "PSC"]) == 7
    @test only(
        canonical_seats.seats[canonical_seats.canonical_party .== "PSC"]
    ) == 7

    expected_psc_ids = Set([
        "90000615998",
        "130000611044",
        "170000616969",
        "160000619724",
        "190000607836",
        "250000615219",
        "270000610932",
    ])
    actual_psc_ids = Set(String.(elected.SQ_CANDIDATO[elected.SG_PARTIDO .== "PSC"]))
    @test actual_psc_ids == expected_psc_ids

    valdevan = only(
        eachrow(candidates[candidates.SQ_CANDIDATO .== "260000621977", :])
    )
    marcio = only(
        eachrow(candidates[candidates.SQ_CANDIDATO .== "260000623622", :])
    )
    @test valdevan.NM_URNA_CANDIDATO == "VALDEVAN NOVENTA"
    @test valdevan.SG_PARTIDO == "PSC"
    @test valdevan.DS_SITUACAO_CANDIDATURA == "INAPTO"
    @test valdevan.DS_SIT_TOT_TURNO == "NÃO ELEITO"
    @test !valdevan.current_loader_counts
    @test marcio.NM_URNA_CANDIDATO == "MARCIO MACÊDO"
    @test marcio.SG_PARTIDO == "PT"
    @test marcio.DS_SITUACAO_CANDIDATURA == "APTO"
    @test marcio.DS_SIT_TOT_TURNO == "ELEITO POR MÉDIA"
    @test marcio.current_loader_counts

end
