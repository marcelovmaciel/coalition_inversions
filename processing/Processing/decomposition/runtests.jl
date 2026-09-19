# Included by the single scientific Julia suite after a fresh analysis.
include(joinpath(@__DIR__, "test_scientific_accounting.jl"))
include(joinpath(@__DIR__, "test_accounting_evidence.jl"))
include(joinpath(@__DIR__, "test_decomposition.jl"))
include(joinpath(@__DIR__, "test_accounting_integration.jl"))
include(joinpath(@__DIR__, "test_party_size_diagnostics.jl"))
include(joinpath(@__DIR__, "test_prose_summaries.jl"))
