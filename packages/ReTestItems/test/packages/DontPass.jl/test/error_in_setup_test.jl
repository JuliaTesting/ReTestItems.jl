@testsetup module SetupThatErrors
    println("SetupThatErrors msg")
    using PackageDoesNotExist
end
@testitem "bad setup, good test" setup=[SetupThatErrors] begin
    @test true
end
@testitem "bad setup, bad test" setup=[SetupThatErrors] begin
    @test false
end
