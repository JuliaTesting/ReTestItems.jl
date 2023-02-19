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
        $store_test_item_setup($TestSetup($nm, $q, $(String(__source__.file))))
    end)
end

###
### testitem
###
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
    name::String
    tags::Vector{Symbol}
    default_imports::Bool
    setups::Vector{Symbol}
    file::String
    line::Int
    project_root::String
    code::Any
    testsetups::Vector{TestSetup} # populated by runtests coordinator
    logstore::IOBuffer
    workerid::Ref{Int} # populated when the test item is scheduled
end

"""
    @testitem "name" [tags=[] setup=[] default_imports=true] begin
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
"""
macro testitem(nm, exs...)
    default_imports = true
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
            else
                error("unknown `@testitem` keyword arg `$(ex.args[1])`")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected `@testitem` to have a body")
    end
    q = QuoteNode(exs[end])
    tls = task_local_storage()
    proj = haskey(tls, :__RE_TEST_PROJECT__) ? tls[:__RE_TEST_PROJECT__] : "."
    esc(quote
        $store_test_item_setup(
            $TestItem($nm, $tags, $default_imports, $setup, $(String(__source__.file)), $(__source__.line), $proj, $q, $TestSetup[], IOBuffer(), Ref{Int}())
        )
    end)
end

function store_test_item_setup(ti::Union{TestItem, TestSetup})
    @debugv 2 "expanding test item/setup: `$(ti.name)`"
    tls = task_local_storage()
    if haskey(tls, :__RE_TEST_INCOMING_CHANNEL__)
        ch = tls[:__RE_TEST_INCOMING_CHANNEL__]
        if ti isa TestSetup
            # don't apply filter on test setups
            put!(chan(ch), ti)
        else
            put!(ch, ti)
        end
    end
    return ti
end
