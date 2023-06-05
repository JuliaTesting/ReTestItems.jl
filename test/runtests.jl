using ReTestItems, Test, Pkg

# Used by test/macros.jl, but macros must be defined at global scope (outside `@testset).
macro foo_test(name)
    _source = QuoteNode(__source__)
    quote
        @testitem $name _source=$_source _run=false begin
            @test true
        end
    end
end

@testset "ReTestItems" verbose=true begin
    # track all workers every created
    ALL_WORKERS = []
    ReTestItems.Workers.GLOBAL_CALLBACK_PER_WORKER[] = w -> push!(ALL_WORKERS, w)
    withenv("RETESTITEMS_RETRIES" => 0) do
        include("workers.jl")
        include("internals.jl")
        include("macros.jl")
        include("integrationtests.jl")
        include("log_capture.jl")
        include("junit_xml.jl")
    end

    # After all tests have run, check we didn't leave Test printing disabled.
    @test Test.TESTSET_PRINT_ENABLE[]
    # After all tests have run, check we didn't leave any workers running.
    @testset "tests removed workers" begin
        @testset "$w" for w in ALL_WORKERS
            if process_running(w.process) || !w.terminated
                @show w
            end
            @test !process_running(w.process)
            @test !isopen(w.socket)
            @test w.terminated
            @test istaskstarted(w.messages) && istaskdone(w.messages)
            @test istaskstarted(w.output) && istaskdone(w.output)
            @test isempty(w.futures)
        end
    end
end
