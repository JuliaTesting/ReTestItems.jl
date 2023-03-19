using ReTestItems

@testitem "Abort" begin
    # we're explicitly crashing the worker here
    ccall(:abort, Cvoid, ())
end
