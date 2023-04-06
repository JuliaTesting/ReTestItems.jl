using ReTestItems

@testitem "Abort" begin
    # we're explicitly crashing the worker here
    ccall(:abort, Cvoid, ())
end

# We want to test that workers which crash get replaced.
# Here we add a test item that should run and pass even after the testitem above crashes.
# For this test to be valid, there must be exactly one worker and this testitem must be
# scheduled _after_ the previous testitem ran and crashed the worker.
@testitem "Test which should run after abort" begin
    @test true
end
