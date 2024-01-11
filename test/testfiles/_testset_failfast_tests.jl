# Testitem containing `@testset failfast=true`
@testitem "Test.jl failfast=true keyword" begin
    @testset failfast=true begin
        @test false
        @test error("ERROR AFTER FAILURE")
        @testset "Bar" begin
            @test false
            @test true
        end
    end
end
