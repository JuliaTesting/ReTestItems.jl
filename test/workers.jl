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
        @test w.process.termsignal == 0
        @test w.process.exitcode == 0
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
        @info "starting testset remote_eval/remote_fetch ($w)"
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

end # workers.jl testset
