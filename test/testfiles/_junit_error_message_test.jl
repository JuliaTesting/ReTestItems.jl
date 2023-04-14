@testitem "testitem with one fail" begin
    @test false
    @testset "pass 1" begin
        @test true
    end
    @testset "pass 2" begin
        @test true
    end
end

@testitem "testitem with one error" begin
    @test X + Y
    @testset "pass 1" begin
        @test true
    end
    @testset "pass 2" begin
        @test true
    end
end

@testitem "testitem with error and failure" begin
    @test X + Y
    @testset "pass 1" begin
        @test true
    end
    @testset "fail 1" begin
        @test false
    end
end
