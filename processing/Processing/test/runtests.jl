using Test, Processing

@testset "Scientific unit and integration tests" begin
    include("test_inputs.jl")
    include("test_coalition_strict.jl")
    include("test_scientific_domains.jl")
    include("test_coalition_period_linkage.jl")
    include("test_representation_profile.jl")
    include("test_cabinet_period_coalescing.jl")
    include("../decomposition/runtests.jl")
end
