@testitem "Failure at toplevel" failfast=true begin
    sleep(0.1)
    @test false
    @test error("ERROR AFTER FAILURE")
    @testset "Bar" begin
        @test false
        @test true
    end
end

@testitem "Failure in nested testset" failfast=true begin
    sleep(0.1)
    @test true
    @testset "Bar" begin
        @test false
        @test error("ERROR AFTER FAILURE")
        @test true
    end
end