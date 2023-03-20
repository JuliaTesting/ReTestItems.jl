@testitem "bar" begin
    @test bar() isa Vector{Float64}
    @test length(bar()) == 3

    @testset "bar values" begin
        @test all(≤(1), bar())
        @test all(≥(0), bar())
    end
end
