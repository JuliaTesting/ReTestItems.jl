@testitem "errors" setup=[ErrorSetup] begin
    @testset "UndefVarError" begin
        @test not_defined + 1 == 4
        # LinearAlgebra not imported
        @test LinearAlgebra.dot(rand(), rand()) < 0
    end
    @testset "evaluated to non-Boolean" begin
        @test ErrorSetup.NON_BOOL
    end
    @testset "package not in project" begin
        # i.e. Example package not installed
        using Example
        @test Example.domath(1) isa Number
    end
end

@testitem "errors at the top level" begin
    @test true  # this is counted
    @assert false  # this stops the rest of the testitem
    @test false  # this is never executed
end

@testsetup module ErrorSetup
    const NON_BOOL = missing
end
