# depends on the testsetup in directory above at `../_testitem_testsetup.jl`
@testitem "foo" setup=[FooSetup] begin
    @test FooSetup.x
end
