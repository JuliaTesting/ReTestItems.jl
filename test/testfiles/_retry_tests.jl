@testsetup module StatefulSetup
    export NUM_RUNS_1, NUM_RUNS_2, NUM_RUNS_3, NUM_RUNS_4
    const NUM_RUNS_1 = Ref{Int}(0)
    const NUM_RUNS_2 = Ref{Int}(0)
    const NUM_RUNS_3 = Ref{Int}(0)
    const NUM_RUNS_4 = Ref{Int}(0)
    println("These are the test setup logs.")
end

@testitem "Pass on second run" setup=[StatefulSetup] begin
    NUM_RUNS_1[] += 1
    write(joinpath(tempdir(), "num_runs_1"), string(NUM_RUNS_1[]))

    x = NUM_RUNS_1[] == 2
    @test x
end

@testitem "Error, then Fail, then Pass" setup=[StatefulSetup] begin
    NUM_RUNS_2[] += 1
    write(joinpath(tempdir(), "num_runs_2"), string(NUM_RUNS_2[]))
    println("These are the logs for run number: ", NUM_RUNS_2[])

    if NUM_RUNS_2[] == 1
        @test not_defined_err
    elseif NUM_RUNS_2[] == 2
        @test 2 + 2 == 5
    else
        @test true
    end
end

@testitem "Has retries=4 and always fails" setup=[StatefulSetup] retries=4 begin
    NUM_RUNS_3[] += 1
    write(joinpath(tempdir(), "num_runs_3"), string(NUM_RUNS_3[]))
    @test false
end

@testitem "Has retries=1 and always fails" setup=[StatefulSetup] retries=1 begin
    NUM_RUNS_4[] += 1
    write(joinpath(tempdir(), "num_runs_4"), string(NUM_RUNS_4[]))
    @test false
end


# For these tests to timeout, must be run with `testitem_timeout < 20`
# Cannot use `StatefulSetup` for testing timeouts, as it will be a new worker
# every retry, so the `setup` will always have been re-evaluated anew.
# Instead we write a new file for each run. We don't use `tempdir()` in case files written
# there get cleaned up as soon as the worker dies.
# We need to write a new file each time for our counting to be correct, so if the assertion
# fails we need to switch to a more robust ways of creating unique filenames.
@testitem "Timeout always" retries=1 begin
    using Random
    tmpdir = mkpath(joinpath("/tmp", "JL_RETESTITEMS_TEST_TMPDIR"))
    filename = joinpath(tmpdir, "num_runs_5_" * randstring())
    @assert !isfile(filename)
    write(filename, "1")
    sleep(20.0)
    @test true
end

@testitem "Timeout first, pass after" retries=1 begin
    using Random
    tmpdir = mkpath(joinpath("/tmp", "JL_RETESTITEMS_TEST_TMPDIR"))
    filename = joinpath(tmpdir, "num_runs_6_" * randstring())
    @assert !isfile(filename)
    is_first_run = !any(contains("num_runs_6"), readdir(tmpdir))
    write(filename, "1")
    if is_first_run
        sleep(20.0)
    end
    @test true
end
