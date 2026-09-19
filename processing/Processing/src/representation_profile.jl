import PyPlot


const REPRESENTATION_PROFILE_YEARS = (2014, 2018, 2022)
const REPRESENTATION_PROFILE_SHARE_TOLERANCE = 1e-6


function _finite_float_column(data::AbstractDataFrame, column::Symbol)
    values = data[!, column]
    any(ismissing, values) &&
        throw(ArgumentError("Column '$column' contains missing values."))

    converted = try
        Float64.(values)
    catch error
        throw(ArgumentError("Column '$column' must be numeric: $(sprint(showerror, error))"))
    end

    all(isfinite, converted) ||
        throw(ArgumentError("Column '$column' contains non-finite values."))
    return converted
end


"""
    prepare_representation_profile(data)

Validate the party-level figure input and add the exact plotted values:
`vote_share_percent`. Preserve the canonical `representation_ratio` input and
validate it independently against vote and seat shares.
"""
function prepare_representation_profile(data::AbstractDataFrame)
    input_row_count = nrow(data)
    input_row_count > 0 || throw(ArgumentError("Input contains no party rows."))

    required_columns = (:election_year, :party, :vote_share, :seat_share, :representation_ratio)
    available_columns = Set(propertynames(data))
    missing_columns = [column for column in required_columns if column ∉ available_columns]
    isempty(missing_columns) ||
        throw(ArgumentError("Input is missing required columns: $missing_columns"))

    plot_data = DataFrame(data; copycols = true)

    year_values = _finite_float_column(plot_data, :election_year)
    all(isinteger, year_values) ||
        throw(ArgumentError("Election years must be whole numbers."))
    plot_data[!, :election_year] = Int.(year_values)
    plot_data[!, :vote_share] = _finite_float_column(plot_data, :vote_share)
    plot_data[!, :seat_share] = _finite_float_column(plot_data, :seat_share)

    actual_years = sort(unique(plot_data.election_year))
    expected_years = collect(REPRESENTATION_PROFILE_YEARS)
    actual_years == expected_years || throw(ArgumentError(
        "Expected election years exactly $expected_years; found $actual_years.",
    ))

    for year in REPRESENTATION_PROFILE_YEARS
        any(==(year), plot_data.election_year) ||
            throw(ArgumentError("Election year $year contains no party rows."))
    end

    invalid_vote_share_rows = findall(plot_data.vote_share .<= 0)
    if !isempty(invalid_vote_share_rows)
        details = join((
            "$(plot_data.election_year[index])/$(plot_data.party[index])=" *
            "$(plot_data.vote_share[index])" for index in invalid_vote_share_rows
        ), ", ")
        throw(ArgumentError(
            "All vote shares must be strictly positive; invalid rows: $details",
        ))
    end

    has_seats = :seats in propertynames(plot_data)
    seat_values = has_seats ? _finite_float_column(plot_data, :seats) : Float64[]

    for year in REPRESENTATION_PROFILE_YEARS
        year_rows = findall(==(year), plot_data.election_year)

        vote_share_sum = sum(plot_data.vote_share[year_rows])
        isapprox(
            vote_share_sum,
            1.0;
            atol = REPRESENTATION_PROFILE_SHARE_TOLERANCE,
            rtol = 0.0,
        ) || throw(ArgumentError(
            "Vote shares for $year sum to $vote_share_sum, not approximately 1.",
        ))

        seat_share_sum = sum(plot_data.seat_share[year_rows])
        isapprox(
            seat_share_sum,
            1.0;
            atol = REPRESENTATION_PROFILE_SHARE_TOLERANCE,
            rtol = 0.0,
        ) || throw(ArgumentError(
            "Seat shares for $year sum to $seat_share_sum, not approximately 1.",
        ))

        if has_seats
            seat_total = sum(seat_values[year_rows])
            isapprox(seat_total, 513.0; atol = 1e-9, rtol = 0.0) ||
                throw(ArgumentError("Seats for $year sum to $seat_total, not 513."))
        end
    end

    plot_data[!, :vote_share_percent] = 100 .* plot_data.vote_share
    plot_data[!, :representation_ratio] = _finite_float_column(plot_data, :representation_ratio)
    all(isapprox(row.representation_ratio, row.seat_share / row.vote_share;
        atol = 1e-12, rtol = 0.0) for row in eachrow(plot_data)) ||
        throw(ArgumentError("Canonical representation ratios disagree with vote/seat shares."))

    zero_seat_parties = has_seats ? seat_values .== 0 : plot_data.seat_share .== 0
    if any(plot_data.representation_ratio[zero_seat_parties] .!= 0)
        invalid_rows = findall(
            zero_seat_parties .& (plot_data.representation_ratio .!= 0),
        )
        details = join((
            "$(plot_data.election_year[index])/$(plot_data.party[index])" for
            index in invalid_rows
        ), ", ")
        throw(ArgumentError(
            "Every zero-seat party must have representation_ratio == 0; " *
            "invalid rows: $details",
        ))
    end

    nrow(plot_data) == input_row_count || throw(ErrorException(
        "Plotting data has $(nrow(plot_data)) rows but input has $input_row_count.",
    ))

    preferred_order = (
        :election_year,
        :party,
        :votes,
        :vote_share,
        :vote_share_percent,
        :seats,
        :seat_share,
        :representation_ratio,
        :quota,
        :seat_diff,
    )
    columns = propertynames(plot_data)
    ordered_columns = [column for column in preferred_order if column in columns]
    append!(ordered_columns, [column for column in columns if column ∉ ordered_columns])
    return select(plot_data, ordered_columns)
end


function _plot_prepared_representation_profile(
    data::AbstractDataFrame,
    output_path::AbstractString,
)
    output_directory = dirname(abspath(output_path))
    isdir(output_directory) ||
        throw(ArgumentError("Output directory does not exist: $output_directory"))

    x_max = maximum(data.vote_share_percent)
    x_padding = 0.04 * x_max
    ratio_min = min(minimum(data.representation_ratio), 1.0)
    ratio_max = max(maximum(data.representation_ratio), 1.0)
    ratio_span = ratio_max - ratio_min
    y_padding = ratio_span > 0 ? 0.05 * ratio_span : 0.05

    lowercase(string(PyPlot.matplotlib.get_backend())) == "agg" ||
        PyPlot.matplotlib.use("Agg"; force = true)
    PyPlot.ioff()

    style = Dict(
        "font.size" => 8.5,
        "axes.labelsize" => 9,
        "axes.titlesize" => 10,
        "xtick.labelsize" => 8,
        "ytick.labelsize" => 8,
        "axes.linewidth" => 0.7,
        "pdf.fonttype" => 42,
    )
    style_context = PyPlot.matplotlib.rc_context(rc = style)
    style_context.__enter__()

    figure = nothing
    try
        figure, axes = PyPlot.subplots(
            1,
            3;
            figsize = (7.35, 3.0),
            sharex = true,
            sharey = true,
            constrained_layout = true,
        )

        plotted_row_count = 0
        for (axis, year) in zip(axes, REPRESENTATION_PROFILE_YEARS)
            year_rows = findall(==(year), data.election_year)
            plotted_row_count += length(year_rows)

            axis.axhline(
                1;
                color = "0.45",
                linewidth = 0.8,
                linestyle = (0, (4, 3)),
                zorder = 1,
            )
            axis.scatter(
                data.vote_share_percent[year_rows],
                data.representation_ratio[year_rows];
                s = 22,
                color = "#315f7d",
                edgecolors = "white",
                linewidths = 0.3,
                zorder = 2,
            )
            axis.set_title(string(year); pad = 5)
            axis.set_xlim(0, x_max + x_padding)
            axis.set_ylim(ratio_min - y_padding, ratio_max + y_padding)
            axis.spines["top"].set_visible(false)
            axis.spines["right"].set_visible(false)
            axis.tick_params(direction = "out", length = 3, width = 0.7)
        end

        plotted_row_count == nrow(data) || throw(ErrorException(
            "Plotted $plotted_row_count rows but input contains $(nrow(data)) rows.",
        ))

        figure.supxlabel("Vote share (%)")
        figure.supylabel("Representation ratio (seat share / vote share)")
        figure.savefig(output_path; format = "pdf", bbox_inches = "tight")
    finally
        figure === nothing || PyPlot.close(figure)
        style_context.__exit__(nothing, nothing, nothing)
    end

    return output_path
end


"""
    plot_representation_profile(data, output_path)

Validate `data` and write the three-panel representation-profile vector PDF.
"""
function plot_representation_profile(data::AbstractDataFrame, output_path::AbstractString)
    prepared = prepare_representation_profile(data)
    return _plot_prepared_representation_profile(prepared, output_path)
end


"""
    representation_profile_summary(data)

Return plotted-party counts, ratio extrema, and zero-seat counts by election.
"""
function representation_profile_summary(data::AbstractDataFrame)
    prepared = prepare_representation_profile(data)
    has_seats = :seats in propertynames(prepared)
    rows = NamedTuple[]

    for year in REPRESENTATION_PROFILE_YEARS
        year_rows = findall(==(year), prepared.election_year)
        zero_seat_count = if has_seats
            seat_values = _finite_float_column(prepared[year_rows, :], :seats)
            count(==(0.0), seat_values)
        else
            count(==(0.0), prepared.seat_share[year_rows])
        end
        push!(rows, (
            election_year = year,
            parties = length(year_rows),
            representation_ratio_min = minimum(prepared.representation_ratio[year_rows]),
            representation_ratio_max = maximum(prepared.representation_ratio[year_rows]),
            zero_seat_parties = zero_seat_count,
        ))
    end

    return DataFrame(rows)
end


"""
    make_representation_profile(input_path, data_output_path, figure_output_path)

Read the existing party-level figure input, write the complete plotted dataset,
and generate the representation-profile PDF from that same validated data.
"""
function make_representation_profile(
    input_path::AbstractString,
    data_output_path::AbstractString,
    figure_output_path::AbstractString,
)
    isfile(input_path) || throw(ArgumentError("Input CSV does not exist: $input_path"))

    data_output_directory = dirname(abspath(data_output_path))
    isdir(data_output_directory) || throw(ArgumentError(
        "Intermediate-data output directory does not exist: $data_output_directory",
    ))

    input_data = CSV.read(input_path, DataFrame)
    prepared = prepare_representation_profile(input_data)
    CSV.write(data_output_path, prepared)
    _plot_prepared_representation_profile(prepared, figure_output_path)
    return prepared
end
