using ReTestItems, Test

@testitemgroup "Group1" begin
    @test ReTestItems.gettestitemgroup() == "Group1"
end

@testsetup TS1 begin
    x = 1
end
@test ReTestItems.gettestsetup(:TS1).name == :TS1

@testitem "TI1" begin
    @test 1 + 1 == 2
end
@test ReTestItems.gettestitem("TI1").name == "TI1"
@test ReTestItems.gettestitem("TI1").file == @__FILE__

@testitem "TI2" tags=[:foo] begin
    @test true
end
@test ReTestItems.gettestitem("TI2").tags == [:foo]

@testitemgroup "GroupTests" begin
    @testitem "TI_grouped" begin
        @test 1 + 1 == 2
    end
end
@testitem "TI_ungrouped" begin
    @test 1 + 1 == 2
end
@test ReTestItems.gettestitem("TI_grouped").group == "GroupTests"
@test ReTestItems.gettestitem("TI_ungrouped").group == nothing

@testsetup FooSetup begin
    x = 1
end
@testitem "Foo" setup=[FooSetup] begin
    @test true
end
@test ReTestItems.gettestitem("Foo").setup == [:FooSetup]
