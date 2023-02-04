@testitem "do_thing Pass" begin
    @test do_thing() isa Vector{Float64}
end
@testitem "do_thing Fail" begin
    @test do_thing() == 1
end
@testitem "do_thing Error" begin
    @test 1 + do_thing() == 2
end
