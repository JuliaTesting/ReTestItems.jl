# this should throw before the tests start running
@testitem "tags wrong type" tags=[:x, "not a symbol"] begin
    @test true
end
