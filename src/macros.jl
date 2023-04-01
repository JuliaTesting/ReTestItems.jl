gettls(k, d) = get(task_local_storage(), k, d)

###
### testsetup
###
"""
    TestSetup(name, code)

A module that a `TestItem` can require to be evaluated before that `TestItem` is run.
Used for declaring code that multiple `TestItem`s rely on.
Should only be created via the `@testsetup` macro.
"""
struct TestSetup
    name::Symbol
    code::Any
    file::String
    line::Int
    project_root::String
    # We keep the IOStream open so that log capture can span mutliple test-items depending on
    # the test setup. This IO object is only for writing on the worker. The coordinator needs
    # to open the file when it needs to read from it.
    logstore::Base.RefValue{IOStream} # Populated and only safe to use on the worker
end

"""
    @testsetup module MyTestSetup
        # code that can be shared between @testitems
    end

A module only used for tests, and which `@testitem`s can depend on.

Useful for setup logic that is used across multiple test items.
The setup will run once, before any `@testitem` that requires it is executed.
If running with multiple processes, each test-setup with be evaluated once on each process.

Each test-setup module will live for the lifetime of the tests.
Mutable state should be avoided, since the order in which test items run is non-deterministic,
and test items may access the same test-setup module concurrently in the same process.

Other than being declared with the `@testsetup` macro, to make then knowable to `@testitem`s,
test-setup modules are just like other modules and can import dependencies and export names.

A `@testitem` depends on a `@testsetup` via the `setup` keyword e.g

    @testitem "MyTests1" setup=[MyTestSetup]
        # tests that require MyTestSetup
    end
"""
macro testsetup(mod)
    mod.head == :module || error("`@testsetup` expects a `module ... end` argument")
    _, name, code = mod.args
    name isa Symbol || error("`@testsetup module` expects a valid module name")
    nm = QuoteNode(name)
    q = QuoteNode(code)
    esc(quote
        $store_test_item_setup($TestSetup($nm, $q, $(String(__source__.file)), $(__source__.line), $gettls(:__RE_TEST_PROJECT__, "."), Ref{IOStream}()))
    end)
end

###
### testitem
###

Base.@kwdef struct PerfStats
    elapsedtime::UInt=0
    bytes::Int=0
    gctime::Int=0
    allocs::Int=0
    compile_time::UInt=0
    recompile_time::UInt=0
end

@static if VERSION < v"1.8"
    macro __tryfinally(ex, fin)
        Expr(:tryfinally,
        :($(esc(ex))),
        :($(esc(fin)))
        )
    end
else
    using Base: @__tryfinally
end

# Adapted from Base.@time
@static if VERSION < v"1.8"
macro timed_with_compilation(ex)
    quote
        while false; end # compiler heuristic: compile this block (alter this if the heuristic changes)
        local stats = Base.gc_num()
        local elapsedtime = time_ns()
        local compile_elapsedtime = Base.cumulative_compile_time_ns_before()
        local val = $(esc(ex))
        compile_elapsedtime = Base.cumulative_compile_time_ns_after() - compile_elapsedtime
        elapsedtime = time_ns() - elapsedtime
        local diff = Base.GC_Diff(Base.gc_num(), stats)
        local out = PerfStats(;
            elapsedtime, bytes=diff.allocd, gctime=diff.total_time, allocs=Base.gc_alloc_count(diff),
            compile_time=compile_elapsedtime, recompile_time=0 # won't show recompile_time
        )
        val, out
    end
end
else
macro timed_with_compilation(ex)
    quote
        Base.Experimental.@force_compile
        local stats = Base.gc_num()
        local elapsedtime = Base.time_ns()
        Base.cumulative_compile_timing(true)
        local compile_elapsedtimes = Base.cumulative_compile_time_ns()
        local val = @__tryfinally($(esc(ex)),
            (elapsedtime = Base.time_ns() - elapsedtime;
            Base.cumulative_compile_timing(false);
            compile_elapsedtimes = Base.cumulative_compile_time_ns() .- compile_elapsedtimes)
        )
        local diff = Base.GC_Diff(Base.gc_num(), stats)
        local out = PerfStats(;
            elapsedtime, bytes=diff.allocd, gctime=diff.total_time, allocs=Base.gc_alloc_count(diff),
            compile_time=first(compile_elapsedtimes), recompile_time=last(compile_elapsedtimes)
        )
        val, out
    end
end
end

mutable struct ScheduledForEvaluation
@static if VERSION < v"1.7"
    value::Threads.Atomic{Bool}
else
    @atomic value::Bool
end
end

@static if VERSION < v"1.7"
    ScheduledForEvaluation() = ScheduledForEvaluation(Threads.Atomic{Bool}(false))
else
    ScheduledForEvaluation() = ScheduledForEvaluation(false)
end

# NOTE: TestItems are serialized across processes for
# distributed testing, so care needs to be taken that
# fields are serialization-appropriate and process-local
# state is managed externally like TestContext in runtests
"""
    TestItem

A single, independently runnable group of tests.
Used to wrap tests that must be run together, similar to a `@testset`, but encapsulating
those test in their own module.
Should only be created via the `@testitem` macro.
"""
struct TestItem
    id::Base.RefValue{Int64} # populated by runtests coordinator once all test items are known
    name::String
    tags::Vector{Symbol}
    default_imports::Bool
    setups::Vector{Symbol}
    retries::Int
    file::String
    line::Int
    project_root::String
    code::Any
    testsetups::Vector{TestSetup} # populated by runtests coordinator
    workerid::Base.RefValue{Int} # populated when the test item is scheduled
    testsets::Vector{DefaultTestSet} # populated when the test item is finished evaluating
    eval_number::Base.RefValue{Int} # to keep track of how many items have been evaluated so far
    stats::Vector{PerfStats} # populated when the test item is finished evaluating
    scheduled_for_evaluation::ScheduledForEvaluation # to keep track of whether the test item has been scheduled for evaluation
end

"""
    @testitem "name" [tags=[] setup=[] retries=0 default_imports=true] begin
        # code that will be run as tests
    end

A single, independently runnable group of tests.

A test item is a standalone block of tests, and cannot access names from the surrounding scope.
Multiple test items may run in parallel, executing on distributed processes.

A `@testitem` can contain a single test:

    @tesitem "Arithmetic" begin
        @test 1 + 1 == 2
    end

Or it can contain many tests, which can be arranged in `@testsets`:

    @testitem "Arithmetic" begin
        @testset "addition" begin
            @test 1 + 2 == 3
            @test 1 + 0 == 1
        end
        @testset "multiplication" begin
            @test 1 * 2 == 2
            @test 1 * 0 == 0
        end
        @test 1 + 2 * 2 == 5
    end

A `@testitem` is wrapped into a module when run, so must import any additional packages:

    @testitem "Arithmetic" begin
        using LinearAlgebra
        @testset "multiplication" begin
            @test dot(1, 2) == 2
        end
    end

The test item's code is evaluated as top-level code in a new module, so it can include imports, define new structs or helper functions, and declare tests and testsets.

    @testitem "DoCoolStuff" begin
        function do_really_cool_stuff()
            # ...
        end
        @testset "cool stuff doing" begin
            @test do_really_cool_stuff()
        end
    end

By default, `Test` and the package being tested will be loaded into the `@testitem`.
This can be disabled by passing `default_imports=false`.

A `@testitem` can use test-specific setup code declared with `@testsetup`, by passing the
name of the test setup module with the `setup` keyword:

    @testsetup module TestIrrationals
        const PI = 3.14159
        const INV_PI = 0.31831
        area(radius) = PI * radius^2
        export PI, INV_PI, area
    end
    @testitem "Arithmetic" setup=[TestIrrationals] begin
        @test 1 / PI ≈ INV_PI atol=1e-6
    end
    @testitem "Geometry" setup=[TestIrrationals] begin
        @test area(1) ≈ PI
    end

If a `@testitem` is known to be flaky, i.e. contains tests that sometimes don't pass,
then you can set it to automatically retry by passing the `retries` keyword.
If a `@testitem` passes on retry, then it will be recorded as passing in the test summary.

    @testitem "Flaky test" retries=1 begin
        @test rand() < 1e-4
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    retries = 0
    tags = Symbol[]
    setup = Any[]
    if length(exs) > 1
        kw_seen = Set{Symbol}()
        for ex in exs[1:end-1]
            ex.head == :(=) || error("`@testitem` options must be passed as keyword arguments")
            kw = ex.args[1]
            kw in kw_seen && error("`@testitem` has duplicate keyword `$kw`")
            push!(kw_seen, kw)
            if kw == :tags
                tags = ex.args[2]
                @assert tags isa Expr "`tags` keyword must be passed a collection of `Symbol`s"
            elseif kw == :default_imports
                default_imports = ex.args[2]
                @assert default_imports isa Bool "`default_imports` keyword must be passed a `Bool`"
            elseif kw == :setup
                setup = ex.args[2]
                @assert setup isa Expr "`setup` keyword must be passed a collection of `@testsetup` names"
                setup = map(Symbol, setup.args)
            elseif kw == :retries
                retries = ex.args[2]
                @assert retries isa Integer "`default_imports` keyword must be passed an `Integer`"
            else
                error("unknown `@testitem` keyword arg `$(ex.args[1])`")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected `@testitem` to have a body")
    end
    q = QuoteNode(exs[end])
    esc(quote
        $store_test_item_setup(
            $TestItem(
                Ref(0), $nm, $tags, $default_imports, $setup, $retries,
                $(String(__source__.file)), $(__source__.line),
                $gettls(:__RE_TEST_PROJECT__, "."),
                $q,
                $TestSetup[],
                Ref{Int}(0),
                $DefaultTestSet[],
                Ref{Int}(0),
                $PerfStats[],
                $ScheduledForEvaluation()
            )
        )
    end)
end

function store_test_item_setup(ti::Union{TestItem, TestSetup})
    @debugv 2 "expanding test item/setup: `$(ti.name)`"
    tls = task_local_storage()
    if ti isa TestItem && haskey(tls, :__RE_TEST_ITEMS__)
        push!(tls[:__RE_TEST_ITEMS__], ti)
    elseif ti isa TestSetup
        # if we're not in a runtests context, add the test setup to the global dict
        setups = get(tls, :__RE_TEST_SETUPS__, GLOBAL_TEST_SETUPS_FOR_TESTING)
        if haskey(setups, ti.name)
            @warn "Encountered duplicate @testsetup with name: `$(ti.name)`. Replacing..."
        end
        setups[ti.name] = ti
    end
    return ti
end
