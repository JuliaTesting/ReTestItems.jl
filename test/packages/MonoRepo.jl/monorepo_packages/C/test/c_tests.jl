@testitem "C_tests" begin
    @test C.test()

    # a test-only dependency
    using Example
    @test Example.domath(5) isa Number
end
