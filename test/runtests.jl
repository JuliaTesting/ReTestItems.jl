using ReTestItems, Test, Pkg

# this file specifically tests *unit* tests for ReTestItems
# so *not* the `runtests` functionality, which utilizes specific
# contrived packages/testfiles

@testitemgroup "Group1" begin
    @test ReTestItems.gettestitemgroup() == "Group1"
end

@testsetup TS1 begin
    x = 1
end
@test ReTestItems.gettestsetup(:TS1).name == :TS1

ti = @testitem "TI1" begin
    @test 1 + 1 == 2
end
@test ReTestItems.gettestitem("TI1").name == "TI1"
@test ReTestItems.gettestitem("TI1").file == @__FILE__
@test ReTestItems.runtestitem(ti) === nothing

ti2 = @testitem "TI2" tags=[:foo] begin
    @test true
end
@test ReTestItems.gettestitem("TI2").tags == [:foo]
@test ReTestItems.runtestitem(ti2) === nothing

@testitemgroup "GroupTests" begin
    @testitem "TI_grouped" begin
        @test 1 + 1 == 2
    end
end
@testitem "TI_ungrouped" begin
    @test 1 + 1 == 2
end
@test ReTestItems.gettestitem("TI_grouped").group == "GroupTests"
@test ReTestItems.gettestitem("TI_ungrouped").group === nothing
@test ReTestItems.runtestitem(ReTestItems.gettestitem("TI_grouped")) === nothing
@test ReTestItems.runtestitem(ReTestItems.gettestitem("TI_ungrouped")) === nothing

@testsetup FooSetup begin
    x = 1
end
@testitem "Foo" setup=[FooSetup] begin
    @test FooSetup.x == 1
end
@test ReTestItems.gettestitem("Foo").setup == [:FooSetup]

# test we can call runtests manually w/ directory
ReTestItems.runtests("packages/NoDeps.jl")

# running a project tests via Pkg also works
cd("packages/NoDeps.jl") do
    Pkg.activate(".")
    Pkg.test()
end
