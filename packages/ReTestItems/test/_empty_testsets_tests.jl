using Test: @testset
using ReTestItems: @testitem

@testitem "Warn on empty test set -- integration test" begin
    @testset "Empty testset" begin end

    @testset "Testset containing an empty testset" begin
        @testset "Inner empty testset" begin end
    end

    @testset "Non-empty testset" begin
        @test true
    end
end
