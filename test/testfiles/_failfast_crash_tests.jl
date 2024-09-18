@testitem "good" begin
    @test true
end
@testitem "bad" begin
    ccall(:abort, Cvoid, ()) # purposefully crash the worker here
end
@testitem "may not run" begin
    @test true
end
