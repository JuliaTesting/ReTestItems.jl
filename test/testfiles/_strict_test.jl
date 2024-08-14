# file that contain a top-level macrocall other than `@testitem` and `@testsetup`
@testitem "ti" begin
    @test 1 == 1
end

@testsetup module StrictFileSetup
    export xyx
    xyx = 1
end

# this macro is defined in `integrationtests.jl` where this file is run.
@_other_macro begin
    @test 1 == 1
end

@_other_macro "other" begin
    @test 1 == 1
end
