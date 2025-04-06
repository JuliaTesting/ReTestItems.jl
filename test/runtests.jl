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
        # junit_xml reference tests are very sensitive to changes in text output which is not
        # stable across minor Julia versions, i.e. we expect these to fail on upcoming Julia
        # releases so we may as well skip them (so PkgEval doesn't always fail for us).
        if !isempty(VERSION.prerelease)
            @warn "Skipping JUnit XML reference tests on unrelease Julia version" VERSION
        elseif Base.Sys.iswindows()
            # https://github.com/JuliaTesting/ReTestItems.jl/issues/209
            @warn "Skipping JUnit XML reference tests on windows"
        else
            include("junit_xml.jl")
        end
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
