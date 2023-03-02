using ReTestItems, Test
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

@testset "log capture -- reporting" begin
    setup1 = @testsetup module TheTestSetup1 end
    setup2 = @testsetup module TheTestSetup2 end
    ti = @testitem "TheTestItem" setup=[TheTestSetup1, TheTestSetup2] begin end
    push!(ti.testsetups, setup1)
    push!(ti.testsetups, setup2)
    ts = Test.DefaultTestSet("dummy")

    iob = IOBuffer()
    println(ti.logstore, "The test item has logs")
    ReTestItems.print_errors_and_captured_logs(iob, ti, ts, verbose=true)
    logs = String(take!(iob))
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")

    println(setup1.logstore, "The setup1 also has logs")
    ReTestItems.print_errors_and_captured_logs(iob, ti, ts, verbose=true)
    logs = String(take!(iob))
    @test contains(logs, " for test setup \"TheTestSetup1\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "The setup1 also has logs")
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")

    println(setup2.logstore, "Even setup2 has logs!")
    ReTestItems.print_errors_and_captured_logs(iob, ti, ts, verbose=true)
    logs = String(take!(iob))
    @test contains(logs, " for test setup \"TheTestSetup1\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "The setup1 also has logs")
    @test contains(logs, " for test setup \"TheTestSetup2\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "Even setup2 has logs!")
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")
end
