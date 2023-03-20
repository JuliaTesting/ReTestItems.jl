using ReTestItems

@testitem "Test item takes 60 seconds" begin
    sleep(60.0)
    @test true
end

