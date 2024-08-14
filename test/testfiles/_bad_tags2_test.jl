# this should throw before the tests start running
@testitem "tags wrong type" tags="not a collaction of symbols" begin
    @test true
end
