# This will only be called from a Julia version that supports interactive threadpool
@testitem "Was spawned with 3,2 threads" begin
    using .Threads
    @test nthreads() == 3
    @test nthreads(:interactive) == 2
end
