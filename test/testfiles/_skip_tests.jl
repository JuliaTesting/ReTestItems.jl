# one test, which is run.
@testitem "1" begin
    @test true
end
# two tests, but whole testitem skipped.
@testitem "2" skip=true begin
    @test true
    @test true
end
# skip expression, returns true
@testitem "3" skip=VERSION < v"3" begin
    no_existent_func()
end
# skip expression, returns false
@testitem "4" skip=VERSION > v"3" begin
    @test true
end
# multi-line skip expression, returns true
@testitem "5" skip=:(using AutoHasEquals; AutoHasEquals isa Module) begin
    @test true
end
