# Used to test the order in which tests are run
@testitem "a. pass" begin
    @test 1 == 1
end
@testitem "b. fail" begin
    @test 1 == 3
end
@testitem "c. pass" begin
    @test 2 == 2
end
@testitem "d. fail" begin
    @test 2 == 4
end
