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
