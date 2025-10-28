@testitem "use a test-only dep" begin
    using Example
    @test Example isa Module
end

@testitem "deps as expected" begin
    using TOML, TestOnlyDeps
    proj = TOML.parsefile(joinpath(pkgdir(TestOnlyDeps), "Project.toml"))
    @test !haskey(proj["deps"], "Example")
end
