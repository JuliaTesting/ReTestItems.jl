# Since we change our log-capturing stategy depending on the number of available threads and
# distributed workers, we run unit tests for log caputre from "_log_capture_tests.jl" in
# separate julia processes that are configured with specific number of threads and workers.
@testset "log capture" begin
    PROJECT_PATH = pkgdir(ReTestItems)
    LOG_CAPTURE_TESTS_PATH = joinpath(pkgdir(ReTestItems), "test", "_log_capture_tests.jl")

    @testset "$julia_args" for julia_args in (["-t1"], ["-t2"], ["-t1", "--procs=2"], ["-t2", "--procs=2"])
        cmd = `$(Base.julia_cmd()) --project=$PROJECT_PATH --color=yes $julia_args $LOG_CAPTURE_TESTS_PATH`
        p = run(pipeline(ignorestatus(cmd); stdout, stderr), wait=false)
        wait(p)
        @test success(p)
    end
end
