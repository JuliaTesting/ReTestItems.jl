@testitem "Test item takes 60 seconds" begin
    sleep(60.0)
    @test true
end

# We want to test that workers which timeout get replaced.
# Here we add a test item that should run and pass even after the testitem above times out.
# For this test to be valid, there must be exactly one worker and this testitem must be
# scheduled _after_ the previous testitem ran and caused us to terminate the worker.
@testitem "Test which should run after timeout" begin
    @test true
end
