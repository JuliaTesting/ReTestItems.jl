@testitem "foo" begin
    @test foo(:bar) == "foo_bar"
    @test foo(2) == "foo_2"
end
