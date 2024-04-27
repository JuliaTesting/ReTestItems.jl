# Unit tests for `ReTestItems.Workers` module
using ReTestItems.Workers
using Test

@testset "workers.jl" verbose=true begin

    w = Worker()
    @testset "correct connected/running states ($w)" begin
        @test w.pid > 0
        @test process_running(w.process)
        @test isopen(w.socket)
        @test !w.terminated
        @test istaskstarted(w.messages) && !istaskdone(w.messages)
        @test istaskstarted(w.output) && !istaskdone(w.output)
        @test isempty(w.futures)
    end
    @testset "clean shutdown ($w)" begin
        close(w)
        @test !process_running(w.process)
        @test !isopen(w.socket)
        @test w.terminated
        @test istaskstarted(w.messages) && istaskdone(w.messages)
        @test istaskstarted(w.output) && istaskdone(w.output)
        @test isempty(w.futures)
    end

    w = Worker()
    @testset "more forceful shutdown ($w)" begin
        @test w.pid > 0
        terminate!(w)
        wait(w)
        @test !process_running(w.process)
        @test !isopen(w.socket)
        @test w.terminated
        @test istaskstarted(w.messages) && istaskdone(w.messages)
        @test istaskstarted(w.output) && istaskdone(w.output)
        @test isempty(w.futures)
    end

    w = Worker()
    @testset "remote_eval/remote_fetch ($w)" begin
        expr = quote
            global x
            x = 101
        end
        ret = remote_fetch(w, expr)
        @test ret == 101
        @test isempty(w.futures) # should be empty since we're not waiting for a response
        # now fetch the remote value
        expr = quote
            global x
            x
        end
        fut = remote_eval(w, expr)
        @test fetch(fut) == 101
        @test isempty(w.futures) # should be empty since we've received all expected responses

        # test remote_call w/ exception
        expr = quote
            error("oops")
        end
        fut = remote_eval(w, expr)
        @test_throws CapturedException fetch(fut)
        close(w)
    end

    # avoid crash logs escaping to stdout, as it confuses PkgEval
    # https://github.com/JuliaTesting/ReTestItems.jl/issues/38
    w = Worker(; worker_redirect_io=devnull)
    @testset "worker crashing ($w)" begin
        expr = quote
            ccall(:abort, Cvoid, ())
        end
        fut = remote_eval(w, expr)
        @test_throws Workers.WorkerTerminatedException fetch(fut)
        wait(w)
        @test !process_running(w.process)
        @test !isopen(w.socket)
        @test w.terminated
        @test istaskstarted(w.messages) && istaskdone(w.messages)
        @test istaskstarted(w.output) && istaskdone(w.output)
        @test isempty(w.futures)
        close(w)
    end

    w = Worker()
    @testset "remote_eval ($w)" begin
        fut = remote_eval(w, :(1 + 2))
        @test fetch(fut) == 3
        # test remote module loading
        fut = remote_eval(w, :(using Test; @test 1 == 1))
        @test fetch(fut) isa Test.Pass
        close(w)
    end

    @testset "CPU profile" begin
        logs = mktemp() do path, io
            w = Worker(threads=VERSION > v"1.9" ? "3,2" : "3", worker_redirect_io=io)
            fut = remote_eval(w, :(sleep(5), yield()))
            sleep(0.5)
            trigger_profile(w, 1, :test)
            fetch(fut)
            close(w)
            flush(io)
            close(io)
            return read(path, String)
        end

        @test occursin(r"Thread 1 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
        @test occursin(r"Thread 2 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
        @test occursin(r"Thread 3 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
        if VERSION > v"1.9"
            @test occursin(r"Thread 4 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
            @test occursin(r"Thread 5 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
            @test !occursin(r"Thread 6 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
        else
            @test !occursin(r"Thread 4 Task 0x\w+ Total snapshots: \d+. Utilization: \d+%", logs)
        end
    end
end # workers.jl testset
