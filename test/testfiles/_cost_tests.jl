# Used to test the order in which tests are run
@testitem "a. no cost" begin
    @test true
end
@testitem "b. cost 100" cost=100 begin
    @test true
end
@testitem "c. no cost" begin
    @test true
end
@testitem "d. cost 50" cost=50 begin
    @test true
end
@testitem "e. cost function" cost=(cfg -> 75) begin
    @test true
end
