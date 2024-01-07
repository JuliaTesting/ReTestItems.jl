@testitem "good" begin
    @test true
end
@testitem "bad" begin
    error("failfast error test")
end
@testitem "may not run" begin
    @test true
end
