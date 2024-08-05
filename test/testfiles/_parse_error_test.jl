# Test case for https://github.com/JuliaTesting/ReTestItems.jl/issues/166
@testitem "file_doesnt_parse" begin
    # Note the missing `]`
    @test ["a", "b"] == ["a", "b"
end
