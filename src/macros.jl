gettls(k, d) = get(task_local_storage(), k, d)

###
### testsetup
###

"""
    TestSetup(name, code)

A module that a `TestItem` can require to be run before that `TestItem` is run.
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
If running with multiple processes, each test-setup with be run once on each process.

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
    (mod isa Expr && mod.head == :module) || error("`@testsetup` expects a `module ... end` argument")
    _, name, code = mod.args
    name isa Symbol || error("`@testsetup module` expects a valid module name")
    nm = QuoteNode(name)
    q = QuoteNode(code)
    esc(quote
        $store_test_setup($TestSetup($nm, $q, $(String(__source__.file)), $(__source__.line), $gettls(:__RE_TEST_PROJECT__, "."), Ref{IOStream}()))
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

# Adapted from Base.@time
macro timed_with_compilation(ex)
    quote
        Base.Experimental.@force_compile
        local stats = Base.gc_num()
        local elapsedtime = Base.time_ns()
        Base.cumulative_compile_timing(true)
        local compile_elapsedtimes = Base.cumulative_compile_time_ns()
        local val = Base.@__tryfinally($(esc(ex)),
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

mutable struct ScheduledForEvaluation
    @atomic value::Bool
end

ScheduledForEvaluation() = ScheduledForEvaluation(false)

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
    number::Base.RefValue{Int64} # populated by runtests coordinator once all test items are known
    name::String
    id::String # in case file/name isn't a sufficiently stable identifier for reporting purposes
    tags::Vector{Symbol}
    default_imports::Bool
    setups::Vector{Symbol}
    retries::Int
    timeout::Union{Int,Nothing} # in seconds
    skip::Union{Bool,Expr}
    file::String
    line::Int
    project_root::String
    code::Any
    testsetups::Vector{TestSetup} # populated by runtests coordinator
    workerid::Base.RefValue{Int} # populated when the test item is scheduled
    testsets::Vector{DefaultTestSet} # populated when the test item is finished running
    eval_number::Base.RefValue{Int} # to keep track of how many items have been run so far
    stats::Vector{PerfStats} # populated when the test item is finished running
    scheduled_for_evaluation::ScheduledForEvaluation # to keep track of whether the test item has been scheduled for evaluation
end
function TestItem(number, name, id, tags, default_imports, setups, retries, timeout, skip, file, line, project_root, code)
    _id = @something(id, repr(hash(name, hash(relpath(file, project_root)))))
    return TestItem(
        number, name, _id, tags, default_imports, setups, retries, timeout, skip, file, line, project_root, code,
        TestSetup[],
        Ref{Int}(0),
        DefaultTestSet[],
        Ref{Int}(0),
        PerfStats[],
        ScheduledForEvaluation(),
    )
end

"""
    @testitem "name" [tags=[] setup=[] retries=0 skip=false default_imports=true] begin
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

The test item's code is run as top-level code in a new module, so it can include imports, define new structs or helper functions, and declare tests and testsets.

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

If a `@testitem` should be aborted after a certain period of time, e.g. the test is known
to occassionally hang, then you can set a timeout (in seconds) by passing the `timeout` keyword.
Note that `timeout` currently only works when tests are run with multiple workers.

    @testitem "Sometimes too slow" timeout=10 begin
        @test sleep(rand(1:100))
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    retries = 0
    timeout = nothing
    tags = Symbol[]
    setup = Any[]
    skip = false
    _id = nothing
    _run = true  # useful for testing `@testitem` itself
    _source = QuoteNode(__source__)
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
                @assert retries isa Integer "`retries` keyword must be passed an `Integer`"
            elseif kw == :timeout
                t = ex.args[2]
                @assert t isa Real "`timeout` keyword must be passed a `Real`"
                @assert t > 0 "`timeout` keyword must be passed a positive number. Got `timeout=$t`"
                timeout = ceil(Int, t)
            elseif kw == :skip
                skip = ex.args[2]
                # If the `Expr` doesn't evaluate to a Bool, throws at runtime.
                @show skip
                @assert skip isa Union{Bool,Expr} "`skip` keyword must be passed a `Bool`"
            elseif kw == :_id
                _id = ex.args[2]
                # This will always be written to the JUnit XML as a String, require the user
                # gives us a String, so that we write exactly what the user expects.
                # If given an `Expr` that doesn't evaluate to a String, throws at runtime.
                @assert _id isa Union{AbstractString,Expr} "`id` keyword must be passed a string"
            elseif kw == :_run
                _run = ex.args[2]
                @assert _run isa Bool "`_run` keyword must be passed a `Bool`"
            elseif kw == :_source
                _source = ex.args[2]
                @assert isa(_source, Union{QuoteNode,Expr})
            else
                error("unknown `@testitem` keyword arg `$(ex.args[1])`")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected `@testitem` to have a body")
    end
    q = QuoteNode(exs[end])
    ti = gensym(:ti)
    @show skip
    esc(quote
        let $ti = $TestItem(
            $Ref(0), $nm, $_id, $tags, $default_imports, $setup, $retries, $timeout, $skip,
            $String($_source.file), $_source.line,
            $gettls(:__RE_TEST_PROJECT__, "."),
            $q,
        )
            if !$_run
                $ti
            elseif $gettls(:__RE_TEST_RUNNING__, false)::$Bool
                $store_test_item($ti)
                $ti
            else # We are not in a `runtests` call, so we run the testitem immediately.
                $runtestitem($ti)
                $nothing
            end
        end
    end)
end

function store_test_item(ti::TestItem)
    tls = task_local_storage()
    if ti isa TestItem && haskey(tls, :__RE_TEST_ITEMS__)
        name = ti.name
        @debugv 2 "expanding test item: `$name`"
        tis, names = tls[:__RE_TEST_ITEMS__]
        if name in names
            project_root = get(task_local_storage(), :__RE_TEST_PROJECT__, ".")
            file = relpath(ti.file, project_root)
            error("Duplicate test item name `$name` in file `$file` at line $(ti.line)")
        end
        push!(names, name)
        push!(tis, ti)
    end
    return ti
end

function store_test_setup(ts::TestSetup)
    @debugv 2 "expanding test setup: `$(ts.name)`"
    tls = task_local_storage()
    if haskey(tls, :__RE_TEST_SETUPS__)
        put!(tls[:__RE_TEST_SETUPS__], ts.name => ts)
    else
        # if we're not in a runtests context, add the test setup to the global dict
        GLOBAL_TEST_SETUPS_FOR_TESTING[ts.name] = ts
    end
    return ts
end
