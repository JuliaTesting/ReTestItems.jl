using ReTestItems.Workers
using ReTestItems.Workers: isterminated
using Test

@testset "Worker basics" begin
    w = Worker()
    @test w.pid > 0
    # test correct connected/running states
    @test process_running(w.process)
    @test isopen(w.socket)
    @test !isterminated(w)
    @test istaskstarted(w.messages) && !istaskdone(w.messages)
    @test istaskstarted(w.output) && !istaskdone(w.output)
    @test isempty(w.futures)
    # test clean shutdown
    close(w)
    @test !process_running(w.process)
    @test !isopen(w.socket)
    @test isterminated(w)
    @test istaskstarted(w.messages) && istaskdone(w.messages)
    @test istaskstarted(w.output) && istaskdone(w.output)
    @test isempty(w.futures)
    # now test more forceful shutdown
    w = Worker()
    @test w.pid > 0
    terminate!(w)
    wait(w)
    @test !process_running(w.process)
    @test !isopen(w.socket)
    @test isterminated(w)
    @test istaskstarted(w.messages) && istaskdone(w.messages)
    @test istaskstarted(w.output) && istaskdone(w.output)
    @test isempty(w.futures)
    # test remote_eval/remote_fetch
    expr = quote
        global x
        x = 101
    end
    w = Worker()
    ret = remote_fetch(w, expr)
    @test ret == 101
    @test isempty(w.futures) # should be empty since we're not waiting for a response
    # now fetch the remote value
    expr = quote
        global x
        x
    end
    fut = remote_eval(w, expr)
    @test length(w.futures) == 1
    @test fetch(fut) == 101
    @test isempty(w.futures) # should be empty since we've received all expected responses
    # test remote_call w/ exception
    expr = quote
        error("oops")
    end
    fut = remote_eval(w, expr)
    @test_throws CapturedException fetch(fut)
    # test worker crashing
    expr = quote
        ccall(:abort, Cvoid, ())
    end
    fut = remote_eval(w, expr)
    @test_throws Workers.WorkerTerminatedException fetch(fut)
    wait(w)
    @test !process_running(w.process)
    @test !isopen(w.socket)
    @test isterminated(w)
    @test istaskstarted(w.messages) && istaskdone(w.messages)
    @test istaskstarted(w.output) && istaskdone(w.output)
    @test isempty(w.futures)
    w = Worker()
    # test remote_eval
    fut = remote_eval(w, :(1 + 2))
    @test fetch(fut) == 3
    # test remote module loading
    fut = remote_eval(w, :(using Test; @test 1 == 1))
    @test fetch(fut) isa Test.Pass
    close(w)
end
