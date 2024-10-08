# file that contain a top-level `___RAI_MACRO_NAME_DONT_USE` macrocall other than `@testitem` and `@testsetup`
# this is unofficially supported i.e. will be dropped in a future non-breaking release
@testitem "ti" begin
    @test 1 == 1
end

@testsetup module RAIFileSetup
    export xyx
    xyx = 1
end

# this macro is defined in `integrationtests.jl` where this file is run.
@test_rel(name="other A", code=begin
    @test 1 == 1
end)

@test_rel(tags=[:xyz], name="other B", code=begin
    @test 2 == 2
end)
