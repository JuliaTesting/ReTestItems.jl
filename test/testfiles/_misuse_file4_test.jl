# file that contain a top-level macrocall other than `@testitem` and `@testsetup`
@testitem "ti" begin
    @test 1 == 1
end

@testsetup module Misuse4FileSetup
    export xyx
    xyx = 1
end

@_other_macro "other" begin
    @test 1 == 1
end
