module AnalysisRunnerCore

using Dates

# Frozen election conventions and observation windows shared by the analysis.
export SUPPORTED_YEARS, vote_kwargs_for_year, mandate_window

const SUPPORTED_YEARS = [2014, 2018, 2022]
const OBSERVED_MANDATE_WINDOWS_BY_ELECTION = Dict(
    2014 => (start_date = Date(2015, 1, 1), end_date = Date(2018, 12, 31)),
    2018 => (start_date = Date(2019, 1, 1), end_date = Date(2022, 12, 31)),
    # The 2022 mandate was ongoing when the cabinet-period data were prepared,
    # so the paper-facing analysis observes it through the latest reliable
    # cabinet-period endpoint in the source data.
    2022 => (start_date = Date(2023, 1, 1), end_date = Date(2026, 3, 19)),
)

function validate_supported_year(year::Integer)
    if !(year in SUPPORTED_YEARS)
        error("Ano não suportado: $year. Anos válidos: $(join(SUPPORTED_YEARS, ", ")).")
    end
    return Int(year)
end

function vote_kwargs_for_year(year::Integer)
    y = validate_supported_year(year)
    if y == 2014
        return (nom_col = "QT_VOTOS_NOMINAIS", leg_col = "QT_VOTOS_LEGENDA")
    elseif y in (2018, 2022)
        return (
            nom_col = "QT_VOTOS_NOMINAIS_VALIDOS",
            leg_col = "QT_TOTAL_VOTOS_LEG_VALIDOS",
        )
    end
    return NamedTuple()
end

function mandate_window(election_year::Integer)
    y = validate_supported_year(election_year)
    window = get(OBSERVED_MANDATE_WINDOWS_BY_ELECTION, y) do
        error("Janela de mandato ausente para $y.")
    end
    start_date = window.start_date
    end_date = window.end_date
    total_days = Dates.value(end_date - start_date) + 1
    return (start_date = start_date, end_date = end_date, total_days = total_days)
end

end
