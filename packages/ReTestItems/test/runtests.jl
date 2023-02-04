using ReTestItems, Test, Pkg, Distributed

@testset "ReTestItems" verbose=true begin
    include("internals.jl")
    include("macrotests.jl")
    include("integrationtests.jl")

    # After all tests have run, check we didn't leave Test printing disabled.
    @test Test.TESTSET_PRINT_ENABLE[]
end
