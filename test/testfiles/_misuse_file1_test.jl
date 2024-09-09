# file that contain a top-level `@testset` call
@testset "not a testitem" begin
    @test true
end
