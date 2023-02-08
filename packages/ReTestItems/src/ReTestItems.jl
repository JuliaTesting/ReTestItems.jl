module ReTestItems

using Base: @lock
using Test: Test, DefaultTestSet, TestSetException
using Distributed: RemoteChannel, @spawnat, nprocs, workers, channel_from_id, remoteref_id, RemoteException
using .Threads: @spawn, nthreads
using Pkg: Pkg
using TestEnv
using LoggingExtras

export runtests, runtestitem
export @testsetup, @testitem
export TestSetup, TestItem

if isdefined(Base, :errormonitor)
    const errmon = Base.errormonitor
else
    const errmon = identity
end

include("macros.jl")
include("testcontext.jl")

# TODO: add `runtests(dirs...)` so from command line we can run things like
# `runtests("test/dir1/", "test/dir4")`
"""
    ReTestItems.runtests()
    ReTestItems.runtests(mod::Module)
    ReTestItems.runtests(dir)

Execute `@testitem` tests.

If no arguments are passed, the current
project is searched for `@testitem`s. If a directory is passed, only that
directory is searched for `@testitem`s. Only files ending in `_test.jl` or
`_tests.jl` will be searched for test items.
"""
function runtests end

default_shouldrun(ti::TestItem) = true

runtests(; kw...) = runtests(default_shouldrun, dirname(Base.active_project()); kw...)
runtests(shouldrun; kw...) = runtests(shouldrun, dirname(Base.active_project()); kw...)
runtests(dir::String; kw...) = runtests(default_shouldrun, dir; kw...)

runtests(pkg::Module; kw...) = runtests(default_shouldrun, pkg; kw...)
function runtests(shouldrun, pkg::Module; kw...)
    dir = pkgdir(pkg)
    isnothing(dir) && error("Could not find directory for `$pkg`")
    return runtests(shouldrun, dir; kw...)
end

function runtests(shouldrun, dir::String; verbose=false)
    if verbose > 0
        LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=verbose) do
            _runtests(shouldrun, dir, verbose)
        end
    else
        return _runtests(shouldrun, dir, verbose)
    end
end

function _runtests(shouldrun, dir::String, verbose)
    # Don't recursively call `runtests` e.g. if we `include` a file which calls it.
    # So we ignore the `runtests(...)` call in `test/runtests.jl` when `runtests(...)`
    # was called from the command line.
    get(task_local_storage(), :__RE_TEST_RUNNING__, false) && return nothing

    # If the test env is already active, then we just need to find the main `Project.toml`
    # to find the package name so we can import the package inside the `@testitem`s.
    # Otherwise, then we need the `Project.toml` to activate the env.
    proj_file = identify_project(dir)
    proj_file == "" && error("Could not find project directory for `$(dir)`")
    @debugv 1 "Running tests in `$dir` for project at `$proj_file`"
    if is_running_test_runtests_jl(proj_file)
        # Assume this is `Pkg.test`, so test env already active.
        @debugv 2 "Running in current environment `$(Base.active_project())`"
        return _runtests_in_current_env(shouldrun, dir, proj_file, verbose)
    else
        @debugv 1 "Activating test environment for `$proj_file`"
        return Pkg.activate(proj_file) do
            TestEnv.activate() do
                _runtests_in_current_env(shouldrun, dir, proj_file, verbose)
            end
        end
    end
end

function _runtests_in_current_env(shouldrun, dir::String, projectfile::String, verbose)
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    setups = Channel{TestSetup}(Inf)
    testitems = RemoteChannel(() -> Channel{TestItem}(Inf))
    results = RemoteChannel(() -> Channel{Tuple{String,DefaultTestSet}}(Inf))
    # run test file including @spawn so we can immediately
    # start executing tests as they're put into our test channel
    fch = FilteredChannel(shouldrun, chan(testitems))
    @debugv 1 "Including tests in $dir"
    include_task = @spawn begin
        include_testfiles!($setups, $fch, $dir)
        close($fch)
        close($setups)
    end
    try
        test_proj = Base.active_project()
        # Avoid `record` printing a summary; we want to print just one summary at the end.
        Test.TESTSET_PRINT_ENABLE[] = false
        parent_ts = DefaultTestSet(proj_name; verbose=true)
        file_testsets = Dict{String,DefaultTestSet}()
        result_task = @spawn begin
            for (file, ts) in $(chan(results))
                filename = relpath(file, $(dirname(projectfile)))
                file_ts = get!(file_testsets, file, DefaultTestSet(filename; verbose=true))
                Test.record(file_ts, ts)
            end
            for file_ts in values(file_testsets)
                Test.record(parent_ts, file_ts)
            end
        end
        @debugv 1 "Scheduling tests on $(nprocs()) processes."
        schedule_tasks = if nprocs() == 1
            ntasks = nthreads()
            @debugv 1 "Spawning $ntasks tasks to run testitems."
            ctx = TestContext(proj_name)
            # we use a single TestSetupModules for all tasks
            ctx.setups_evaled = TestSetupModules()
            errmon(@spawn process_test_setups!($ctx, $setups))
            [@spawn schedule_testitems!($ctx, chan(testitems), chan(results)) for _ in 1:ntasks]
        else
            # create a setups RemoteChannel per worker
            setups_chans = [RemoteChannel(() -> Channel{TestSetup}(Inf)) for _ in workers()]
            # spawn a task that broadcasts from coordinator-local setups channel to worker remote setup channels
            errmon(@spawn broadcast_test_setups!($setups, $setups_chans))
            [@spawnat(p, schedule_remote_testitems!(test_proj, proj_name, setups_chans[i], testitems, results, verbose)) for (i, p) in enumerate(workers())]
        end
        foreach(wait, schedule_tasks)
        # once all test items have been run, close the results channel
        close(results)
        # make sure to wait on result_task to finish finalizing testitem testsets
        wait(result_task)
        Test.TESTSET_PRINT_ENABLE[] = true # reenable printing so our `finish` prints
        Test.print_test_errors(parent_ts)  # print details of each failure/error
        Test.finish(parent_ts)             # print summary of total passes/failures/errors
    finally
        Test.TESTSET_PRINT_ENABLE[] = true
        # we wouldn't expect to need to wait on include_task
        # since schedule_testitems! shouldn't return until the test channel
        # is closed, but in case of unexpected errors, this at least
        # ensures that all tasks spawned by runtests finish before it returns
        wait(include_task)
    end
    return nothing
end

is_invalid_state(ex::Exception) = false
is_invalid_state(ex::InvalidStateException) = true
is_invalid_state(ex::RemoteException) = ex.captured.ex isa InvalidStateException

function process_test_setups!(ctx::TestContext, setups)
    while true
        try
            ts = take!(setups)
            println("Processing test setup: $(ts.name) from $(ts.file)")
            ctx.setups_quoted[String(ts.name)] = ts
            !isopen(setups) && !isready(setups) && break
        catch ex
            if !isopen(setups) && is_invalid_state(ex)
                break
            else
                rethrow(ex)
            end
        end
    end
    # once we've exited the loop, we know there aren't any more test setups coming
    # so let's cleanup our test context by closing all the futures eval tasks might
    # be waiting on (in the case a test item depends on a non-existent test setup)
    @lock ctx.setups_quoted.lock for (_, v) in ctx.setups_quoted.setups
        close(v)
    end
    return nothing
end

function broadcast_test_setups!(setups::Channel, remotechans::Vector{<:RemoteChannel})
    for ts in setups
        for rc in remotechans
            put!(rc, ts)
        end
    end
    return nothing
end

# Check if the file at `filepath` is a "test file"
# i.e. if it ends with `_test.jl` or `_tests.jl`.
istestfile(filepath) = endswith(filepath, "_test.jl") || endswith(filepath, "_tests.jl")

# for each directory, kick off a recursive test-finding task
function include_testfiles!(setups::Channel, testitems::FilteredChannel, dir)
    # don't recurse into subprojects
    subproject_root = nothing
    @sync for (root, _, files) in walkdir(dir)
        if subproject_root !== nothing && startswith(root, subproject_root)
            continue
        elseif _project_file(root) !== nothing && root != dir
            subproject_root = root
            continue
        end
        for file in files
            # channel should only be closed if there was an error
            isopen(testitems) || return nothing
            filepath = joinpath(root, file)
            istestfile(filepath) || continue
            @debugv 1 "Including test items from file `$filepath`"
            @spawn try
                task_local_storage(:__RE_TEST_RUNNING__, true) do
                    task_local_storage(:__RE_TEST_CHANNEL__, $testitems) do
                        # ensure any `@testsetup` macros are expanded into
                        # our setups channel
                        task_local_storage(:TestSetup, $setups) do
                            Base.include(Main, $filepath)
                        end
                    end
                end
            catch e
                @error "Error including test items from file `$filepath`" exception=(e, catch_backtrace())
                # use the exception to close our TestItem channel so it gets propagated
                close($testitems, e)
                close($setups, e)
            end
        end
    end
    return nothing
end

function is_running_test_runtests_jl(projectfile::String)
    file_running = get(task_local_storage(), :SOURCE_PATH, nothing)
    file_test_runtests_jl = Pkg.Operations.testfile(dirname(projectfile))
    return file_running == file_test_runtests_jl
end

function _project_file(env::String)
    for proj in Base.project_names
        project_file = joinpath(env, proj)
        if Base.isfile_casesensitive(project_file)
            return project_file
        end
    end
    return nothing
end

# identify project file for which we're running tests
function identify_project(dir)
    projectfile = ""
    path = abspath(dir)
    while true
        path == "/" && break
        pf = _project_file(path)
        if pf !== nothing
            projectfile = pf
            break
        end
        path = dirname(path)
    end
    return projectfile
end

function with_source_path(f, path)
    tls = task_local_storage()
    prev = get(tls, :SOURCE_PATH, nothing)
    tls[:SOURCE_PATH] = path
    try
        return f()
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
end

function schedule_remote_testitems!(proj::String, proj_name::String, setups::RemoteChannel, testitems::RemoteChannel, results::RemoteChannel, verbose)
    # activate the project for which we're running tests on the worker process
    Pkg.activate(proj) do
        # on remote workers, we need a per-worker TestSetupModules
        ctx = TestContext(proj_name)
        ctx.setups_evaled = TestSetupModules()
        errmon(@spawn process_test_setups!($ctx, $setups))
        if verbose > 0
            LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=verbose) do
                schedule_testitems!(ctx, testitems, results)
            end
        else
            schedule_testitems!(ctx, testitems, results)
        end
    end
end

function schedule_testitems!(ctx::TestContext, testitems, results)
    while true
        try
            ti = take!(testitems)
            @debugv 2 "Scheduling test item: $(ti.name) from $(ti.file)"
            runtestitem(ti, ctx, results)
            !isopen(testitems) && !isready(testitems) && break
        catch ex
            if !isopen(testitems) && is_invalid_state(ex)
                break
            else
                rethrow(ex)
            end
        end
    end
    return nothing
end

function ensure_setup!(ctx::TestContext, setup::Symbol)
    return nameof(getmodule(ctx.setups_evaled, setup) do
        # we haven't eval-ed this setup module yet
        ts = ctx.setups_quoted[String(setup)]
        mod_expr = :(module $(gensym(ts.name)) end)
        # replace the module expr body with our @testsetup code
        mod_expr.args[3] = ts.code
        return with_source_path(ts.file) do
            Core.eval(Main, mod_expr)
        end
    end)
end

# convenience method/globals for testing
const GLOBAL_TEST_CONTEXT_FOR_TESTING = TestContext("ReTestItems")
reset_global_test_context!() = empty!(GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_quoted.setups)

# assumes any required setups were expanded outside of a runtests context
function runtestitem(ti::TestItem)
    # make a fresh TestSetupModules for each testitem run
    GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_evaled = TestSetupModules()
    runtestitem(ti, GLOBAL_TEST_CONTEXT_FOR_TESTING, nothing)
end

function runtestitem(ti::TestItem, ctx::TestContext, results::Union{Channel, RemoteChannel, Nothing})
    name = ti.name
    @debugv 1 "Running test item." name
    # start with empty block expr and build up our @testitem module body
    body = Expr(:block)
    if ti.default_imports
        push!(body.args, :(using Test))
        if !isempty(ctx.projectname)
            # this obviously assumes we're in an environment where projectname is reachable
            push!(body.args, :(Base.@lock Base.require_lock using $(Symbol(ctx.projectname))))
        end
    end
    for setup in ti.setup
        # TODO(nhd): Consider implementing some affinity to setups, so that we can
        # prefer to send testitems to the workers that have already eval'd setups.
        # Or maybe allow user-configurable grouping of test items by worker?
        # Or group them by file by default?

        # ensure setup has been evaled before
        ts_mod = ensure_setup!(ctx, setup)
        # eval using in our @testitem module
        @debugv 1 "Importing setup $setup." name
        push!(body.args, Expr(:using, Expr(:., :., :., ts_mod)))
        # ts_mod is a gensym'd name so that setup modules don't clash
        # so we set a const alias inside our @testitem module to make things work
        push!(body.args, :(const $setup = $ts_mod))
    end
    @debugv 1 "Setup done." name
    ts = DefaultTestSet(name; verbose=true)
    Test.push_testset(ts)
    # add our @testitem quoted code to module body expr
    append!(body.args, ti.code.args)
    mod_expr = :(module $(gensym(name)) end)
    # replace the module body with our built up expr
    mod_expr.args[3] = body
    try
        with_source_path(ti.file) do
            try
                Core.eval(Main, mod_expr)
            catch err
                err isa InterruptException && rethrow()
                # Handle exceptions thrown outside a `@test` in the body of the @testitem:
                # Copied from Test.@testset's catch block:
                Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
                                    (Test.Base).current_exceptions(),
                                    LineNumberNode(ti.line, ti.file)))
            end
        end
    catch e
        e isa InterruptException && rethrow()
        @error "Error running testitem $(repr(ti.name)) from file `$(ti.file)`" exception=(e, catch_backtrace())
    finally
        ts1 = Test.pop_testset()
        @assert ts1 === ts
        try
            Test.finish(ts) # This will throw an exception if any of the tests failed.
        catch e
            e isa TestSetException || rethrow()
        end
        if results !== nothing
            put!(results, (ti.file, convert_results_to_be_transferrable(ts)))
        end
    end
    @debugv 1 "Test item done." name
    return nothing
end

# copied from XUnit.jl
function convert_results_to_be_transferrable(ts::Test.AbstractTestSet)
    results_copy = copy(ts.results)
    empty!(ts.results)
    for t in results_copy
        push!(ts.results, convert_results_to_be_transferrable(t))
    end
    return ts
end

function convert_results_to_be_transferrable(res::Test.Pass)
    if res.test_type == :test_throws
        # A passed `@test_throws` contains the stacktrace for the (correctly) thrown exception
        # This exception might contain references to some types that are not available
        # on other processes (e.g., the master process that consolidates the results)
        # The stack-trace is converted to string here.
        return Test.Pass(:test_throws, nothing, nothing, string(res.value))
    else
        # Ignore the `res.data` field for Test.Pass, since it can contain values interpolated
        # into the Expr, which may only be valid in this process.
        return Test.Pass(res.test_type, res.orig_expr, nothing, res.value, res.source, res.message_only)
    end
    return res
end

convert_results_to_be_transferrable(x) = x

end # module ReTestItems
