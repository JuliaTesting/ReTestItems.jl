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


# For this to timeout, must be run with `testitem_timeout < 60`
# Cannot use `StatefulSetup` for this as it will be a new worker
# every retry, so the `setup` will always have been re-evaluated anew.
@testitem "Timeout always" retries=1 begin
    write(tempname() * "_num_runs_5", "1")
    sleep(60.0)
    @test true
end
