@testitem "NoDeps-testitem" begin
    @testset "inner-testset" begin
        @test answer() == 42
    end
    println("NoDeps tests done!")
end
