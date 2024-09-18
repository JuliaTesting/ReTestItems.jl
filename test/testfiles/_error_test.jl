@testitem "Test that throws outside of a @test" begin
    # to make testing easier, we sleep a little to guarantee the format in which the timing
    # info will print (else it could potentially print "<0.1 secs")
    sleep(0.5)
    error("throws")
    @test true
end
