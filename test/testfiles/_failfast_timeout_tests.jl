@testitem "good" begin
    @test true
end
@testitem "bad" begin
    # expected to be run with `timeout=x` with some `x < 10`
    sleep(10)
    @test true
end
@testitem "may not run" begin
    @test true
end
