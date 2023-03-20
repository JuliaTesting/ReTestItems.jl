@testitem "MonoRepo tests" begin
    @test MonoRepo.test()
    @test MonoRepo.testC()
    @test true
end
