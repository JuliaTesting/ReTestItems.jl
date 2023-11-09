# 1 PASS.
@testitem "no skip, 1 pass" begin
    @test true
end
# 1 PASS, 1 FAIL
@testitem "skip false, 1 pass, 1 fail" skip=false begin
    @test true
    @test false
end
# two tests; SKIPPED.
@testitem "skip true" skip=true begin
    @test true
    @test true
end
# skip expression false, 2 PASS
@testitem "skip expr false, 2 pass" skip=VERSION > v"3" begin
    @test true
    @test true
end
# testitem has error, skip expression true; SKIPPED
@testitem "skip expr true" skip=VERSION < v"3" begin
    no_existent_func()
end
# multi-line skip expression returns true; SKIPPED
@testitem "skip expr block true" skip=:(using AutoHashEquals; AutoHashEquals isa Module) begin
    @test false
end
