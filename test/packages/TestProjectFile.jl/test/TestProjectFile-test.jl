@testitem "TestProjectFile" begin
    @testset "test-only dep on InlineStrings" begin
        using InlineStrings
        @test foo() isa Number
    end
end
