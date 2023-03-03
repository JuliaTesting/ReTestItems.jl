module ReTestItems

using Base: @lock
using Test: Test, DefaultTestSet, TestSetException
using Distributed: RemoteChannel, @spawnat, nprocs, workers, channel_from_id, remoteref_id, RemoteException, myid
using .Threads: @spawn, nthreads
using Pkg: Pkg
using TestEnv
using Logging
using LoggingExtras
using ContextVariablesX
using DataStructures: DataStructures, dequeue!, PriorityQueue
import Distributed

export runtests, runtestitem
export @testsetup, @testitem
export TestSetup, TestItem

const STALLED_LIMIT_SECONDS = 30*60

if isdefined(Base, :errormonitor)
    const errmon = Base.errormonitor
else
    const errmon = identity
end

include("macros.jl")
include("testcontext.jl")
include("log_capture.jl")

function __init__()
    DEFAULT_STDOUT[] = stdout
    DEFAULT_STDERR[] = stderr
    DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
    DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
    return nothing
end

"""
    ReTestItems.runtests()
    ReTestItems.runtests(mod::Module)
    ReTestItems.runtests(paths::AbstractString...)

Execute `@testitem` tests.

Only files ending in `_test.jl` or `_tests.jl` will be searched for test items.

If no arguments are passed, the current project is searched for `@testitem`s.
If directory or file paths are passed, only those directories and files are searched.

# Keywords
- `verbose::Bool`: If `true`, print the logs from all `@testitem`s to `stdout`.
  Otherwise, logs are only printed for `@testitem`s with errors or failures.
  Defaults to `true` when Julia is running in an interactive session, otherwise `false`.
- `name::Union{Regex,AbstractString,Nothing}=nothing`: Used to filter `@testitem`s by their name.
    `AbstractString` input will only keep the `@testitem` that exactly matches `name`,
    `Regex` can be used to partially match mutilple `@testitem`s. By default, no filtering is
    applied.
- `tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing`: Used to filter `@testitem`s by their tags.
    A single tag can be used to match any `@testitem` that contains it, when multiple tags
    are provided, only `@testitem`s that contain _all_ of the tags will be run.
    By default, no filtering is applied.

`name` and `tags` filters are applied together and only those `@testitem`s that pass both filters
will be run.
"""
function runtests end

# We assume copy-pasting test name would be the most common use-case
_shouldrun(name::AbstractString, ti_name) = name == ti_name
# Regex used for partial matches on test item name (commonly used with XUnit.jl)
_shouldrun(pattern::Regex, ti_name) = contains(ti_name, pattern)
_shouldrun(tags::AbstractVector{Symbol}, ti_tags) = issubset(tags, ti_tags)
# All tags must be present in the test item, aka we use AND chaining for tags.
# OR chaining would make it hard to run more specific subsets of tests + one can run
# mutliple independents `runtests` with AND chaining to get most of the benefits of OR chaining
# (with the caveat that overlaps would be run multiple times)
_shouldrun(tag::Symbol, ti_tags) = tag in ti_tags
_shouldrun(::Nothing, x) = true

default_shouldrun(ti::TestItem) = true

runtests(; kw...) = runtests(default_shouldrun, dirname(Base.active_project()); kw...)
runtests(shouldrun; kw...) = runtests(shouldrun, dirname(Base.active_project()); kw...)
runtests(paths::AbstractString...; kw...) = runtests(default_shouldrun, paths...; kw...)

runtests(pkg::Module; kw...) = runtests(default_shouldrun, pkg; kw...)
function runtests(shouldrun, pkg::Module; kw...)
    dir = pkgdir(pkg)
    isnothing(dir) && error("Could not find directory for `$pkg`")
    src = joinpath(dir, "src")
    test = joinpath(dir, "test")
    return runtests(shouldrun, src, test; kw...)
end

function runtests(
    shouldrun,
    paths::AbstractString...;
    verbose=isinteractive(),
    debug=0,
    name::Union{Regex,AbstractString,Nothing}=nothing,
    tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing,
)
    shouldrun_combined = ti -> shouldrun(ti) && _shouldrun(name, ti.name) && _shouldrun(tags, ti.tags)

    debuglvl = Int(debug)
    if debuglvl > 0
        LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=debuglvl) do
            _runtests(shouldrun_combined, paths, verbose, debuglvl)
        end
    else
        return _runtests(shouldrun_combined, paths, verbose, debuglvl)
    end
end

function _runtests(shouldrun, paths, verbose::Bool, debug::Int)
    # Don't recursively call `runtests` e.g. if we `include` a file which calls it.
    # So we ignore the `runtests(...)` call in `test/runtests.jl` when `runtests(...)`
    # was called from the command line.
    get(task_local_storage(), :__RE_TEST_RUNNING__, false) && return nothing

    # If passed multiple directories/files, we assume/require they share the same environment.
    dir = first(paths)
    @assert dir isa AbstractString
    # If the test env is already active, then we just need to find the main `Project.toml`
    # to find the package name so we can import the package inside the `@testitem`s.
    # Otherwise, then we need the `Project.toml` to activate the env.
    proj_file = identify_project(dir)
    proj_file == "" && error("Could not find project directory for `$(dir)`")
    @debugv 1 "Running tests in `$paths` for project at `$proj_file`"
    if is_running_test_runtests_jl(proj_file)
        # Assume this is `Pkg.test`, so test env already active.
        @debugv 2 "Running in current environment `$(Base.active_project())`"
        return _runtests_in_current_env(shouldrun, paths, proj_file, verbose, debug)
    else
        @debugv 1 "Activating test environment for `$proj_file`"
        return Pkg.activate(proj_file) do
            TestEnv.activate() do
                _runtests_in_current_env(shouldrun, paths, proj_file, verbose, debug)
            end
        end
    end
end

function _runtests_in_current_env(shouldrun, paths, projectfile::String, verbose::Bool, debug::Int)
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    incoming = Channel{Union{TestItem, TestSetup}}(Inf)
    testitems = RemoteChannel(() -> Channel{TestItem}(Inf))
    results = RemoteChannel(() -> Channel{Tuple{TestItem,DefaultTestSet}}(Inf))
    # run test file including @spawn so we can immediately
    # start executing tests as they're put into our test channel
    fch = FilteredChannel(shouldrun, incoming)
    @debugv 1 "Including tests in $paths"
    include_task = @spawn begin
        # Wrapping with the logger that was set before we eval'd any user code to
        # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
        with_logger(current_logger()) do
            @debugv 2 "Begin including $paths"
            include_testfiles!($fch, $projectfile, $paths)
            @debugv 2 "Done including $paths"
            close($fch)
        end
    end
    try
        test_proj = Base.active_project()
        # Avoid `record` printing a summary; we want to print just one summary at the end.
        result_task = @spawn begin
            # Wrapping with the logger that was set before we eval'd any user code to
            # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
            with_logger(current_logger()) do
                process_results!($(chan(results)), $proj_name, $(dirname(projectfile)), $verbose)
            end
        end
        @debugv 1 "Starting task to process incoming test items/setups"
        errmon(@spawn begin
            # Wrapping with the logger that was set before we eval'd any user code to
            # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
            with_logger(current_logger()) do
                process_incoming!($incoming, $(chan(testitems)))
            end
        end)
        @debugv 1 "Scheduling tests on $(nprocs()) processes."
        schedule_tasks = if nprocs() == 1
            # This is where we disable printing for the multithreaded executor case.
            Test.TESTSET_PRINT_ENABLE[] = false
            ntasks = nthreads()
            ntasks > 1 && _setup_multithreaded_log_capture()
            @debugv 1 "Spawning $ntasks tasks to run testitems."
            ctx = TestContext(proj_name)
            # we use a single TestSetupModules for all tasks
            ctx.setups_evaled = TestSetupModules()
            [@spawn schedule_testitems!($ctx, chan(testitems), chan(results), $verbose) for _ in 1:ntasks]
        else
            # spawn a task that broadcasts from coordinator-local setups channel to worker remote setup channels
            # We don't schedule any testitems on worker 1 as it handles file includes and result collection
            [
                @spawnat(p, schedule_remote_testitems!(test_proj, proj_name, testitems, results, verbose, debug))
                for p in workers()
            ]
        end
        foreach(wait, schedule_tasks)
        # once all test items have been run, close the results channel
        close(results)
        # make sure to wait on result_task to finish finalizing testitem testsets
        testset = fetch(result_task)
        Test.TESTSET_PRINT_ENABLE[] = true # reenable printing so our `finish` prints
        Test.finish(testset)               # print summary of total passes/failures/errors
    finally
        Test.TESTSET_PRINT_ENABLE[] = true
        # we wouldn't expect to need to wait on include_task
        # since schedule_testitems! shouldn't return until the test channel
        # is closed, but in case of unexpected errors, this at least
        # ensures that all tasks spawned by runtests finish before it returns
        wait(include_task)
        (nthreads() > 1 && nprocs() == 1) && _teardown_multithreaded_log_capture()
    end
    return nothing
end

is_invalid_state(ex::Exception) = false
is_invalid_state(ex::InvalidStateException) = true
is_invalid_state(ex::RemoteException) = ex.captured.ex isa InvalidStateException

# Struct for hierarchical testset handling. Used for structuring the final table of results.
# Stores directory and file level testsets ordered by their depth in the directory tree.
struct TestSetTree
    queue::PriorityQueue{String,Int}
    testsets::Dict{String,DefaultTestSet}

    function TestSetTree()
        return new(
            PriorityQueue{String,Int}(Base.Order.Reverse),
            Dict{String,DefaultTestSet}()
        )
    end
end

_depth(path) = length(splitpath(path))

function DataStructures.dequeue!(tree::TestSetTree)
    name = dequeue!(tree.queue)
    return pop!(tree.testsets, name)
end

Base.isempty(tree::TestSetTree) = isempty(tree.queue)

function Base.get!(f, tree::TestSetTree, key::String)
    if haskey(tree.testsets, key)
        return tree.testsets[key]
    else
        return get!(tree, key, f())
    end
end

function Base.get!(tree::TestSetTree, key::String, value::DefaultTestSet)
    get!(tree.queue, key, _depth(key))
    return get!(tree.testsets, key, value)
end


function process_results!(results::Channel, project_name::String, project_root::String, verbose::Bool)
    project_ts = DefaultTestSet(project_name; verbose=true)
    testsets = TestSetTree()
    for (ti, ts) in results
        print_errors_and_captured_logs(ti, ts; verbose=verbose)
        report_empty_testsets(ti, ts)
        filename = relpath(ti.file, project_root)
        file_ts = get!(() -> DefaultTestSet(filename; verbose=true), testsets, filename)
        Test.record(file_ts, ts)
    end
    while !isempty(testsets)
        ts = dequeue!(testsets)
        # We want the final summary to print the directory structure alphabetically.
        # We know `ts.results` is a vector of `DefaultTestSet`s (not `Result`s).
        sort!(ts.results, by=(ts)->(ts.description))
        dir_name = dirname(ts.description)
        if isempty(dir_name)
            # We're at the root of the project, so record to the top-most testset.
            Test.record(project_ts, ts)
        else
            dir_ts = get!(() -> DefaultTestSet(dir_name; verbose=true), testsets, dir_name)
            Test.record(dir_ts, ts)
        end
    end
    sort!(project_ts.results, by=(ts)->(ts.description))
    return project_ts
end

function process_incoming!(incoming::Channel, testitems::Channel)
    setups = Dict{Symbol, TestSetup}()
    waiting = Dict{Symbol, Vector{TestItem}}() # maps TestSetup.name to list of TestItems waiting for that setup
    for ti in incoming
        @debugv 1 "Processing test item/setup: $(repr(ti.name)) from $(ti.file):$(ti.line)"
        if ti isa TestSetup
            setups[ti.name] = ti
            # check if any test items are waiting for this setup
            if haskey(waiting, ti.name)
                for wti in waiting[ti.name]
                    push!(wti.testsetups, ti)
                    if length(wti.testsetups) == length(wti.setups)
                        # all required setups have been seen, so we can run this test item
                        put!(testitems, wti)
                    end
                end
                delete!(waiting, ti.name)
            end
        elseif ti isa TestItem
            # check if we know about all the required setups
            for s in ti.setups
                if haskey(setups, s)
                    push!(ti.testsetups, setups[s])
                else
                    push!(get!(() -> TestItem[], waiting, s), ti)
                end
            end
            if length(ti.setups) == length(ti.testsetups)
                # we have all the required setups, so we can run this test item
                put!(testitems, ti)
            end
        end
    end
    # we know no more test items/setups are coming, so now we deal w/ any test items that are stuck waiting
    seen = Set{String}()
    for (_, tis) in waiting
        for ti in tis
            ti.name in seen && continue
            @debugv 1 "Test item $(repr(ti.name)) from $(ti.file):$(ti.line) is stuck waiting for at least one of $(ti.setups)"
            # by forcing evaluation, we'll get an appropriate error message when the test setup isn't found
            put!(testitems, ti)
            push!(seen, ti.name)
        end
    end
    # close the testitems channel so schedule_testitems! knows to stop
    close(testitems)
    return nothing
end

# Check if the file at `filepath` is a "test file"
# i.e. if it ends with `_test.jl` or `_tests.jl`.
istestfile(filepath) = endswith(filepath, "_test.jl") || endswith(filepath, "_tests.jl")


# walkdir that accepts both files and directories
walkdir(path::AbstractString) = isfile(path) ? _walkfile(path) : Base.walkdir(path)
_walkfile(path::AbstractString) = [(dirname(path), String[], [basename(path)])]

# for each directory, kick off a recursive test-finding task
function include_testfiles!(incoming::FilteredChannel, projectfile, paths)
    subproject_root = nothing  # don't recurse into directories with their own Project.toml.
    project_dirname = dirname(projectfile)
    @sync for path in paths
        has_tests = false
        for (root, _, files) in ReTestItems.walkdir(path)
            if subproject_root !== nothing && startswith(root, subproject_root)
                @debugv 1 "Skipping files in `$root` in subproject `$subproject_root`"
                continue
            elseif _project_file(root) !== nothing && abspath(_project_file(root)) != projectfile
                subproject_root = root
                continue
            end
            for file in files
                # channel should only be closed if there was an error
                isopen(incoming) || return nothing
                filepath = joinpath(root, file)
                istestfile(filepath) || continue
                has_tests = true
                @debugv 1 "Including test items from file `$filepath`"
                @spawn try
                    task_local_storage(:__RE_TEST_RUNNING__, true) do
                        task_local_storage(:__RE_TEST_INCOMING_CHANNEL__, $incoming) do
                            task_local_storage(:__RE_TEST_PROJECT__, $(project_dirname)) do
                                Base.include(Main, $filepath)
                            end
                        end
                    end
                catch e
                    @error "Error including test items from file `$filepath`" exception=(e, catch_backtrace())
                    # use the exception to close our TestItem channel so it gets propagated
                    close($incoming, e)
                end
            end
        end
        has_tests || @warn "No test file found at path $(repr(path))."
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

function schedule_remote_testitems!(
    proj::String,
    proj_name::String,
    testitems::RemoteChannel,
    results::RemoteChannel,
    verbose::Bool,
    debug::Int,
)
    # activate the project for which we're running tests on the worker process
    Pkg.activate(proj) do
        # This is where we disable printing for the distributed executor case (called on each worker).
        Test.TESTSET_PRINT_ENABLE[] = false
        # on remote workers, we need a per-worker TestSetupModules
        ctx = TestContext(proj_name)
        ctx.setups_evaled = TestSetupModules()
        if debug > 0
            LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=debug) do
                schedule_testitems!(ctx, testitems, results, verbose)
            end
        else
            schedule_testitems!(ctx, testitems, results, verbose)
        end
    end
end

function schedule_testitems!(ctx::TestContext, testitems, results, verbose::Bool)
    while true
        try
            ti = take!(testitems)
            ti.workerid[] = myid()
            @debugv 2 "Scheduling test item$(_on_worker()): $(repr(ti.name)) from $(ti.file):$(ti.line)"
            runtestitem(ti, ctx, results; verbose=verbose)
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

function ensure_setup!(ctx::TestContext, setup::Symbol, setups::Vector{TestSetup})
    mods = ctx.setups_evaled
    @lock mods.lock begin
        mod = get(mods.modules, setup, nothing)
        if mod !== nothing
            # we've eval-ed this module before, so just return the module name
            return nameof(mod)
        end
        # we haven't eval-ed this module before, so we need to eval it
        i = findfirst(s -> s.name == setup, setups)
        if i === nothing
            # if the setup hasn't been eval-ed before and we don't have it
            # in our testsetups, then it was never found during including
            # in that case, we return the expected test setup module name
            # which will turn into a `using $setup` in the test item
            # which will throw an appropriate error
            return setup
        end
        ts = setups[i]
        # In case the setup fails to eval, we discard its logs -- the setup will be
        # attempted to eval for each of the dependent test items and we'd for each
        # failed test item, we'd print the cumulative logs from all the previous attempts.
        truncate(ts.logstore, 0)
        mod_expr = :(module $(gensym(ts.name)) end)
        # replace the module expr body with our @testsetup code
        mod_expr.args[3] = ts.code
        newmod = _capture_logs(ts; close_pipe=false) do
            with_source_path(() -> Core.eval(Main, mod_expr), ts.file)
        end
        # add the new module to our TestSetupModules
        mods.modules[setup] = newmod
        return nameof(newmod)
    end
end

# convenience method/globals for testing
const GLOBAL_TEST_CONTEXT_FOR_TESTING = TestContext("ReTestItems")

# assumes any required setups were expanded outside of a runtests context
function runtestitem(ti::TestItem, setups::Vector{TestSetup}=TestSetup[], results=nothing; kw...)
    # make a fresh TestSetupModules for each testitem run
    GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_evaled = TestSetupModules()
    empty!(ti.testsetups)
    append!(ti.testsetups, setups)
    runtestitem(ti, GLOBAL_TEST_CONTEXT_FOR_TESTING, results; kw...)
end

function runtestitem(
    ti::TestItem, ctx::TestContext, results::Union{Channel, RemoteChannel, Nothing};
    verbose::Bool=false, finish_test::Bool=true
)
    name = ti.name
    log_running(ti)
    # start with empty block expr and build up our @testitem module body
    body = Expr(:block)
    if ti.default_imports
        push!(body.args, :(using Test))
        if !isempty(ctx.projectname)
            # this obviously assumes we're in an environment where projectname is reachable
            push!(body.args, :(Base.@lock Base.require_lock using $(Symbol(ctx.projectname))))
        end
    end
    ts = DefaultTestSet(name; verbose=verbose)
    Test.push_testset(ts)
    timer = let ti=ti
        Timer(_->log_stalled(ti), STALLED_LIMIT_SECONDS)
    end
    try
        for setup in ti.setups
            # TODO(nhd): Consider implementing some affinity to setups, so that we can
            # prefer to send testitems to the workers that have already eval'd setups.
            # Or maybe allow user-configurable grouping of test items by worker?
            # Or group them by file by default?

            # ensure setup has been evaled before
            ts_mod = ensure_setup!(ctx, setup, ti.testsetups)
            # eval using in our @testitem module
            @debugv 1 "Importing setup for test item $(repr(name)) $(setup)$(_on_worker())."
            # We look up the testsetups from Main (since tests are eval'd in their own
            # temporary anonymous module environment.)
            push!(body.args, Expr(:using, Expr(:., :Main, ts_mod)))
            # ts_mod is a gensym'd name so that setup modules don't clash
            # so we set a const alias inside our @testitem module to make things work
            push!(body.args, :(const $setup = $ts_mod))
        end
        @debugv 1 "Setup for test item $(repr(name)) done$(_on_worker())."
        # add our @testitem quoted code to module body expr
        append!(body.args, ti.code.args)
        mod_expr = :(module $(gensym(name)) end)
        # replace the module body with our built up expr
        mod_expr.args[3] = body
        # eval the testitem into a temporary module, so that all results can be GC'd
        # once the test is done and sent over the wire. (However, note that anonymous modules
        # aren't always GC'd right now: https://github.com/JuliaLang/julia/issues/48711)
        environment = Module()
        _capture_logs(ti) do
            with_source_path(() -> Core.eval(environment, mod_expr), ti.file)
        end
    catch err
        err isa InterruptException && rethrow()
        # Handle exceptions thrown outside a `@test` in the body of the @testitem:
        # Copied from Test.@testset's catch block:
        Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
            (Test.Base).current_exceptions(),
            LineNumberNode(ti.line, ti.file)))
    finally
        close(timer)
        ts1 = Test.pop_testset()
        @assert ts1 === ts
        try
            finish_test && Test.finish(ts) # This will throw an exception if any of the tests failed.
        catch e
            e isa TestSetException || rethrow()
        end
        if results !== nothing
            put!(results, (ti, convert_results_to_be_transferrable(ts)))
        end
    end
    @debugv 1 "Test item $(repr(name)) done$(_on_worker())."
    return ts
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
