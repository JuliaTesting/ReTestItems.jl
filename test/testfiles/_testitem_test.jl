# depends on the testsetup in `_testitem_testsetup.jl`
@testitem "foo" setup=[FooSetup] begin
    @test FooSetup.x
end
