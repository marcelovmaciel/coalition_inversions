#!/usr/bin/env julia

ENV["MPLBACKEND"] = "Agg"

using Processing
using CSV
using DataFrames


const REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))
const INPUT_PATH = joinpath(
    REPOSITORY_ROOT,
    "build", "results", "domains",
    "figure_data",
    "party_vote_share_vs_seat_share.csv",
)
const DATA_OUTPUT_PATH = joinpath(
    REPOSITORY_ROOT,
    "build", "results", "domains",
    "figure_data",
    "party_representation_profile.csv",
)
const FIGURE_OUTPUT_PATH = get(
    ENV,
    "REPRESENTATION_PROFILE_FIGURE_PATH",
    joinpath(
        REPOSITORY_ROOT,
        "build", "assets",
        "party_representation_profile.pdf",
    ),
)


mkpath(dirname(FIGURE_OUTPUT_PATH))
data = Processing.make_representation_profile(
    INPUT_PATH,
    DATA_OUTPUT_PATH,
    FIGURE_OUTPUT_PATH,
)
summary = Processing.representation_profile_summary(data)

println("Wrote $FIGURE_OUTPUT_PATH")
