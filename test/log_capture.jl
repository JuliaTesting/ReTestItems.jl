# Unit tests for log capturing functionality in `src/log_capture.jl`
using ReTestItems
using Test

@testset "log_capture.jl" verbose=true begin

@testset "log capture" begin
    PROJECT_PATH = pkgdir(ReTestItems)
    LOG_CAPTURE_TESTS_PATH = joinpath(pkgdir(ReTestItems), "test", "_test_log_capture.jl")

    @testset "$log_display" for log_display in (:eager, :batched, :issues)
        # Need to run in a separate process to force --color=yes in CI.
        cmd = addenv(`$(Base.julia_cmd()) --project=$PROJECT_PATH --color=yes $LOG_CAPTURE_TESTS_PATH`, "LOG_DISPLAY" => log_display)
        p = run(pipeline(ignorestatus(cmd); stdout, stderr), wait=false)
        wait(p)
        @test success(p)
    end
end

@testset "Workers print in color" begin
    project_path = pkgdir(ReTestItems)
    code = """
    using ReTestItems.Workers
    remote_fetch(Worker(), :(printstyled("this better ber red\n", color=:red)))
    """
    # Need to run in a separate process to force --color=yes in CI.
    logs = IOCapture.capture(color=true) do
        run(`$(Base.julia_cmd()) --project=$project_path --color=yes -e $code`)
    end
    @test endswith(logs.output,  "\e[31mthis better ber red\e[39m\n")
end

@testset "log capture -- reporting" begin
    setup1 = @testsetup module TheTestSetup1 end
    setup2 = @testsetup module TheTestSetup2 end
    ti = @testitem "TheTestItem" setup=[TheTestSetup1, TheTestSetup2] begin end
    push!(ti.testsetups, setup1)
    push!(ti.testsetups, setup2)
    push!(ti.testsets, Test.DefaultTestSet("dummy"))
    setup1.logstore[] = open(ReTestItems.logpath(setup1), "w")
    setup2.logstore[] = open(ReTestItems.logpath(setup2), "w")

    iob = IOBuffer()
    # The test item logs are deleted after `print_errors_and_captured_logs`
    open(io->write(io, "The test item has logs"), ReTestItems.logpath(ti, 1), "w")
    ReTestItems.print_errors_and_captured_logs(iob, ti, 1, logs=:batched)
    logs = String(take!(iob))
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")

    open(io->write(io, "The test item has logs"), ReTestItems.logpath(ti, 1), "w")
    println(setup1.logstore[], "The setup1 also has logs")
    flush(setup1.logstore[])
    ReTestItems.print_errors_and_captured_logs(iob, ti, 1, logs=:batched)
    logs = String(take!(iob))
    @test contains(logs, " for test setup \"TheTestSetup1\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "The setup1 also has logs")
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")

    open(io->write(io, "The test item has logs"), ReTestItems.logpath(ti, 1), "w")
    println(setup2.logstore[], "Even setup2 has logs!")
    flush(setup2.logstore[])
    ReTestItems.print_errors_and_captured_logs(iob, ti, 1, logs=:batched)
    logs = String(take!(iob))
    @test contains(logs, " for test setup \"TheTestSetup1\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "The setup1 also has logs")
    @test contains(logs, " for test setup \"TheTestSetup2\" (dependency of \"TheTestItem\") at ")
    @test contains(logs, "Even setup2 has logs!")
    @test contains(logs, " for test item \"TheTestItem\" at ")
    @test contains(logs, "The test item has logs")
end

@testset "default_log_display_mode" begin
    # default_log_display_mode(report::Bool, nworkers::Integer, interactive::Bool)

    @test ReTestItems.default_log_display_mode(false, 0, true) == :eager
    @test ReTestItems.default_log_display_mode(false, 1, true) == :eager
    @test ReTestItems.default_log_display_mode(false, 2, true) == :batched
    @test ReTestItems.default_log_display_mode(false, 3, true) == :batched
    @test_throws AssertionError ReTestItems.default_log_display_mode(false, -1, true)
    @test ReTestItems.default_log_display_mode(false, 0, false) == :issues
    @test ReTestItems.default_log_display_mode(false, 1, false) == :issues
    @test ReTestItems.default_log_display_mode(false, 2, false) == :issues
    @test ReTestItems.default_log_display_mode(false, 3, false) == :issues
    @test_throws AssertionError ReTestItems.default_log_display_mode(false, -1, false)

    @test ReTestItems.default_log_display_mode(true, 0, true) == :batched
    @test ReTestItems.default_log_display_mode(true, 1, true) == :batched
    @test ReTestItems.default_log_display_mode(true, 2, true) == :batched
    @test ReTestItems.default_log_display_mode(true, 3, true) == :batched
    @test_throws AssertionError ReTestItems.default_log_display_mode(true, -1, true)
    @test ReTestItems.default_log_display_mode(true, 0, false) == :issues
    @test ReTestItems.default_log_display_mode(true, 1, false) == :issues
    @test ReTestItems.default_log_display_mode(true, 2, false) == :issues
    @test ReTestItems.default_log_display_mode(true, 3, false) == :issues
    @test_throws AssertionError ReTestItems.default_log_display_mode(true, -1, false)
end

@testset "time_print" begin
    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=0)
    @test String(take!(io)) == "0 secs"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=123.456 * 1e9)
    @test String(take!(io)) == "123.5 secs"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=0.09 * 1e9)
    @test String(take!(io)) == "<0.1 secs"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, gctime=0.5*1e9)
    @test String(take!(io)) == "1.0 secs (50.0% GC)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, gctime=0.0009*1e9)
    @test String(take!(io)) == "1.0 secs (<0.1% GC)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.5*1e9)
    @test String(take!(io)) == "1.0 secs (50.0% compile)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.0009*1e9)
    @test String(take!(io)) == "1.0 secs (<0.1% compile)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.5*1e9, recompile_time=0.5*1e9)
    @test String(take!(io)) == "1.0 secs (50.0% compile, 50.0% recompile)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.0009*1e9, recompile_time=0.0009*1e9)
    @test String(take!(io)) == "1.0 secs (<0.1% compile, <0.1% recompile)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.5*1e9, recompile_time=0.5*1e9, gctime=0.5*1e9)
    @test String(take!(io)) == "1.0 secs (50.0% compile, 50.0% recompile, 50.0% GC)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.0009*1e9, recompile_time=0.0009*1e9, gctime=0.0009*1e9)
    @test String(take!(io)) == "1.0 secs (<0.1% compile, <0.1% recompile, <0.1% GC)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, allocs=1, bytes=1024)
    @test String(take!(io)) == "1.0 secs, 1 alloc (1.024 KB)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, allocs=2, bytes=1_024_000)
    @test String(take!(io)) == "1.0 secs, 2 allocs (1.024 MB)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.5*1e9, recompile_time=0.5*1e9, gctime=0.5*1e9, allocs=9001, bytes=1024_000_000)
    @test String(take!(io)) == "1.0 secs (50.0% compile, 50.0% recompile, 50.0% GC), 9.00 K allocs (1.024 GB)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=0.0009*1e9, recompile_time=0.0009*1e9, gctime=0.0009*1e9, allocs=9_001_000, bytes=1024_000_000_000)
    @test String(take!(io)) == "1.0 secs (<0.1% compile, <0.1% recompile, <0.1% GC), 9.00 M allocs (1.024 TB)"

    io = IOBuffer()
    ReTestItems.time_print(io, elapsedtime=1e9, compile_time=1e9, recompile_time=1e9, gctime=1e9, allocs=9_001_000_000, bytes=1024_000_000_000_000)
    @test String(take!(io)) == "1.0 secs (100.0% compile, 100.0% recompile, 100.0% GC), 9.00 B allocs (1.024 PB)"
end

end # log_capture.jl testset
