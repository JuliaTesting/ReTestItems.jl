module ReTestItems

using Base: @lock
using Test: Test, DefaultTestSet
using Distributed: RemoteChannel, @spawnat, nprocs, workers, channel_from_id, remoteref_id
using .Threads: @spawn

export runtests, runtestitem
export @testitemgroup, @testsetup, @testitem
export TestSetup, TestItem

# pass in a type T, value, and str key
# we get a Dict{String, T} from task_local_storage
# and set key => value
settls!(::Type{T}, val, str::String) where {T} =
    setindex!(get!(() -> Dict{String, T}(), task_local_storage(), nameof(T))::Dict{String, T}, val, str)

"""
    @testitemgroup name begin
        ...
    end

Temporarily sets a test item group name
in task local storage that test items will
pick up when their macro is expanded. Useful
for grouping test items together when multiple
test items are run together.
"""
macro testitemgroup(name, body)
    esc(quote
        task_local_storage(:__RE_TEST_ITEM_GROUP__, $name) do
            $body
        end
    end)
end

# get any test item group that has been set in task_local_storage
gettestitemgroup() = get(task_local_storage(), :__RE_TEST_ITEM_GROUP__, nothing)

"""
    SetupSet()

A set of test setups. Used to keep track of
which test setups have been evaluated on a given
process.
"""
struct SetupSet
    lock::ReentrantLock
    modules::Dict{Symbol, Module} # set of @testsetup modules that have already been evaled
end

SetupSet() = SetupSet(ReentrantLock(), Dict{Symbol, Module}())

Base.lock(ss::SetupSet) = lock(ss.lock)
Base.unlock(ss::SetupSet) = unlock(ss.lock)
Base.getindex(ss::SetupSet, key::Symbol) = getindex(ss.modules, key)
Base.setindex!(ss::SetupSet, val::Module, key::Symbol) = setindex!(ss.modules, val, key)
Base.haskey(ss::SetupSet, ey::Symbol) = haskey(ss.modules, key)

"""
    TestSetup

A module that a `TestItem` can require to be evaluated before that `TestItem` is run.
Used for declaring code that multiple `TestItem`s rely on.
Should only be created via the `@testsetup` macro.
"""
struct TestSetup
    name::Symbol
    code::Any
end

"""
    @testsetup MyTestSetup begin
        # code that can be shared between @testitems
    end
"""
macro testsetup(name, code)
    name isa Symbol || error("expected `name` to be a valid module name")
    nm = QuoteNode(name)
    q = QuoteNode(code)
    esc(quote
        $settls!($TestSetup, $TestSetup($nm, $q), $(String(name)))
    end)
end

# retrieve a test setup by name
gettestsetup(name) = task_local_storage(nameof(TestSetup))[String(name)]

"""
    SetupContext()

A context for test setups. Used to keep track of
`@testsetup`-expanded `TestSetup`s and a `SetupSet`
for a given process; used in `runtestitem` to ensure
any setups relied upon by the `@testitem` are evaluated
on the process that will run the test item.
"""
mutable struct SetupContext
    # name => quote'd code
    setups::Dict{String, TestSetup}
    # name => eval'd code
    setupset::SetupSet

    # user of SetupContext must create and set the
    # SetupSet explicitly, since they must be process-local
    # and shouldn't be serialized across processes
    SetupContext() = new(Dict{String, TestSetup}())
end

# NOTE: TestItems are serialized across processes for
# distributed testing, so care needs to be taken that
# fields are serialization-appropriate and process-local
# state is managed externally like SetupContext in runtests
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
    setup::Vector{Symbol}
    file::String
    code::Any
    group::Union{String, Nothing}
end

"""
    @testitem TestItem "name" [tags=[] setup=[] default_imports=true] begin
        # code that will be run as a test
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    tags = Symbol[]
    setup = Any[]
    if length(exs) > 1
        for ex in exs[1:end-1]
            ex.head == :(=) || error("@testitem options must be passed as keyword arguments")
            if ex.args[1] == :tags
                tags = ex.args[2]
            elseif ex.args[1] == :default_imports
                default_imports = ex.args[2]
            elseif ex.args[1] == :setup
                setup = ex.args[2]
                @assert setup isa Expr "setup keyword must be passed a collection of testsetup names"
                setup = map(Symbol, setup.args)
            else
                error("unknown @testitem keyword arg $(ex.args[1])")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected @testitem to have a body")
    end
    q = QuoteNode(exs[end])
    ti = gensym()
    esc(quote
        $ti = $TestItem($nm, $tags, $default_imports, $setup, $(String(__source__.file)), $q, $(gettestitemgroup)())
        $settls!($TestItem, $ti, $nm)
        if haskey(task_local_storage(), :__RE_TEST_CHANNEL__)
            put!(task_local_storage(:__RE_TEST_CHANNEL__), $ti)
        end
        $ti
    end)
end

gettestitem(name) = task_local_storage(nameof(TestItem))[String(name)]

# get the /src and /test directories for a project/package
function _src_and_test(root_dir)
    src_dir = joinpath(root_dir, "src")
    test_dir = joinpath(root_dir, "test")
    # Don't need to check `isdir` because `walkdir` just ignores non-existent directories.
    return (src_dir, test_dir)
end

"""
    ReTestItems.runtests()
    ReTestItems.runtests(mod::Module)
    ReTestItems.runtests(dirs...)

Execute `@testitem` tests. If no arguments are passed, the current
project is searched for `src` and `test` directories. If a module
is passed, the `src` and `test` directories are searched for that
module. If directories are passed, they are searched directly for
`@testitem`s.
"""
function runtests end

default_shouldrun(ti::TestItem) = true

runtests() = runtests(default_shouldrun, dirname(Base.active_project()))
runtests(dir::String, dirs::String...) = runtests(default_shouldrun, dir, dirs...)

runtests(pkg::Module) = runtests(default_shouldrun, pkg)
function runtests(shouldrun, pkg::Module)
    dir = pkgdir(pkg)
    isnothing(dir) && error("Could not find directory for `$pkg`")
    return runtests(shouldrun, _src_and_test(dir)...)
end

chan(ch::RemoteChannel) = channel_from_id(remoteref_id(ch))

# FilteredChannel applies a filtering function `f` to items
# when you try to `put!` and only puts if `f` returns true.
struct FilteredChannel{F, T}
    f::F
    ch::T
end

Base.put!(ch::FilteredChannel, x) = ch.f(x) && put!(ch.ch, x)
Base.take!(ch::FilteredChannel) = take!(ch.ch)
Base.close(ch::FilteredChannel) = close(ch.ch)
Base.close(ch::FilteredChannel, e::Exception) = close(ch.ch, e)
Base.isopen(ch::FilteredChannel) = isopen(ch.ch)

function runtests(shouldrun, dirs::String...)
    setupctx = SetupContext()
    # Don't recursively call `runtests` e.g. if we `include` a file which calls it.
    get(task_local_storage(), :__RE_TEST_RUNNING__, false) && return nothing
    ch = RemoteChannel(() -> Channel{TestItem}(Inf))
    # run test file including @spawn so we can immediately
    # start executing tests as they're put into our test channel
    fch = FilteredChannel(shouldrun, chan(ch))
    @debug "Including tests in $dirs."
    errormonitor(@spawn include_testfiles!($(setupctx.setups), $fch, dirs...))
    @debug "Scheduling tests on $(nprocs()) processes."
    if nprocs() == 1
        schedule_testitems!(setupctx, chan(ch))
    else
        futures = [@spawnat(p, schedule_testitems!(setupctx, ch)) for p in workers()]
        foreach(wait, futures)
    end
    return nothing
end

# TODO: change to include any file under `test/`. Will need take full filepath.
function istestfile(filename)
    endswith(filename, "_test.jl") || endswith(filename, "_tests.jl") || filename == "runtests.jl"
end

# for each directory, kick off a recursive test-finding task
function include_testfiles!(setups::Dict{String, TestSetup}, ch::FilteredChannel, dirs...)
    @sync for dir in dirs
        @debug "Including test items from directory `$dir`"
        isdir(dir) || @warn "`$dir` directory doesn't exist"
        for (root, _, files) in walkdir(dir)
            for file in files
                # channel should only be closed if there was an error
                isopen(ch) || return nothing
                istestfile(file) || continue
                @debug "Including test items from file `$filepath`"
                filepath = joinpath(root, file)
                errormonitor(@spawn begin
                    try
                        task_local_storage(:__RE_TEST_RUNNING__, true) do
                            task_local_storage(:__RE_TEST_CHANNEL__, $ch) do
                                # ensure any `@testsetup` macros are expanded into
                                # our setups Dict
                                task_local_storage(nameof(TestSetup), $setups) do
                                    include($filepath)
                                end
                            end
                        end
                    catch e
                        @error "error including test file $filepath" exception=(e, catch_backtrace())
                        # use the exception to close our TestItem channel so it gets propagated
                        close($ch, e)
                    end
                end)
            end
        end
    end
    # because we @sync waited on all our spawned tasks to finish, we know
    # at this point we've finished including all test files in dirs, so
    # now we close our test channel to signal that no more will be added
    @debug "All testfiles included."
    close(ch)
    @debug "Closed test channel."
    return nothing
end

function schedule_testitems!(setupctx::SetupContext, ch::Channel)
    setupctx.setupset = SetupSet()
    @sync for ti in ch
        @spawn runtestitem($ti, $setupctx)
    end
    return nothing
end

function schedule_testitems!(setupctx::SetupContext, ch::RemoteChannel)
    setupctx.setupset = SetupSet()
    while true
        try
            ti = take!(ch)
            runtestitem(ti, setupctx)
            !isopen(ch) && !isready(ch) && break
        catch e
            if isa(e, InvalidStateException) && !isopen(ch)
                break
            else
                rethrow(e)
            end
        end
    end
    return nothing
end

function ensure_setup!(setupctx::SetupContext, setup::Symbol)
    @lock setupctx.setupset begin
        if !haskey(setupctx.setupset, setup)
            # we haven't eval-ed this setup module yet
            ts = setupctx.setups[String(setup)]
            mod = Core.eval(Main, :(module $(gensym(ts.name)) end))
            setupctx.setupset[setup] = mod
        end
        return nameof(setupctx.setupset[setup])
    end
end

# convenience method for testing
# assumes any required setups were expanded in current task_local_storage
function runtestitem(ti::TestItem)
    ctx = SetupContext()
    ctx.setups = get(() -> Dict{String, TestSetup}(), task_local_storage(), nameof(TestSetup))
    ctx.setupset = SetupSet()
    runtestitem(ti, ctx)
end

function runtestitem(ti::TestItem, setupctx::SetupContext)
    name = ti.name
    @debug "Running test item." name
    mod = Core.eval(Main, :(module $(gensym(name)) end))
    if ti.default_imports
        Core.eval(mod, :(using Test))
        # TODO: know which package a TestItem belongs to.
        # if ti.package !== nothing
        #     Core.eval(mod, :(using $(ti.package)))
        # end
    end
    for setup in ti.setup
        # ensure setup has been evaled before
        ts_mod = ensure_setup!(setupctx, setup)
        # eval using in our @testitem module
        Core.eval(mod, :(using $ts_mod))
    end
    @debug "Setup done." name
    Test.push_testset(DefaultTestSet(name; verbose=true))
    Core.eval(mod, ti.code)
    Test.finish(Test.pop_testset())
    @debug "Test item done." name
    return nothing
end

end # module ReTestItems
