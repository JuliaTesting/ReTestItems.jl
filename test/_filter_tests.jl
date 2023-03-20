using ReTestItems

@testitem "Test item no tags" begin
    @test true
end
@testitem "Test item tag1" tags=[:tag1] begin
    @test true
end
@testitem "Test item tag1 tag2" tags=[:tag1, :tag2] begin
    @test true
end
