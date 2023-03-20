module ReTestItems

using Base: @lock
using Dates: format, now
using Test: Test, DefaultTestSet, TestSetException
using Distributed: Distributed, RemoteChannel, @spawnat, nprocs, addprocs, RemoteException, myid, remotecall_eval, ProcessExitedException
using .Threads: @spawn, nthreads
using Pkg: Pkg
using TestEnv
using Logging
using LoggingExtras

export runtests, runtestitem
export @testsetup, @testitem
export TestSetup, TestItem, TestItemResult

const RETESTITEMS_TEMP_FOLDER = mkpath(joinpath(tempdir(), "ReTestItemsTempLogsDirectory"))
const DEFAULT_TEST_ITEM_TIMEOUT = 30*60

if isdefined(Base, :errormonitor)
    const errmon = Base.errormonitor
else
    const errmon = identity
end

# copyied from REPL.jl
function softscope(@nospecialize ex)
    if ex isa Expr
        h = ex.head
        if h === :toplevel
            ex′ = Expr(h)
            map!(softscope, resize!(ex′.args, length(ex.args)), ex.args)
            return ex′
        elseif h in (:meta, :import, :using, :export, :module, :error, :incomplete, :thunk)
            return ex
        elseif h === :global && all(x->isa(x, Symbol), ex.args)
            return ex
        else
            return Expr(:block, Expr(:softscope, true), ex)
        end
    end
    return ex
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
- `testitem_timeout::Int`: The number of seconds to wait until a `@testitem` is marked as failed.
  Defaults to 30 minutes. Note timeouts are currently only applied when `nworkers > 0`.
- `nworkers::Int`: The number of workers to use for running `@testitem`s. Default 0. Can also be set
  using the `RETESTITEMS_NWORKERS` environment variable.
- `nworker_threads::Int`: The number of threads to use for each worker. Defaults to 2.
  Can also be set using the `RETESTITEMS_NWORKER_THREADS` environment variable.
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
    return runtests(shouldrun, dir; kw...)
end

function runtests(
    shouldrun,
    paths::AbstractString...;
    nworkers::Int=parse(Int, get(ENV, "RETESTITEMS_NWORKERS", "0")),
    nworker_threads::Int=parse(Int, get(ENV, "RETESTITEMS_NWORKER_THREADS", "2")),
    testitem_timeout::Real=DEFAULT_TEST_ITEM_TIMEOUT,
    verbose=isinteractive(),
    debug=0,
    name::Union{Regex,AbstractString,Nothing}=nothing,
    tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing,
)
    paths′ = filter(paths) do p
        if !ispath(p)
            @warn "No such path $(repr(p))"
            return false
        elseif !(is_test_file(p) || is_testsetup_file(p)) && isfile(p)
            @warn "$(repr(p)) is not a test file"
            return false
        else
            return true
        end
    end
    # If we were given paths but none were valid, then nothing to run.
    !isempty(paths) && isempty(paths′) && return nothing
    shouldrun_combined(ti) = shouldrun(ti) && _shouldrun(name, ti.name) && _shouldrun(tags, ti.tags)
    mkpath(RETESTITEMS_TEMP_FOLDER) # ensure our folder wasn't removed
    save_current_stdio()
    nworkers = max(0, nworkers)
    debuglvl = Int(debug)
    if debuglvl > 0
        LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=debuglvl) do
            _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, testitem_timeout, verbose, debuglvl)
        end
    else
        return _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, testitem_timeout, verbose, debuglvl)
    end
end

function _runtests(shouldrun, paths, nworkers::Int, nworker_threads::Int, testitem_timeout::Real, verbose::Bool, debug::Int)
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
        return _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, testitem_timeout, verbose, debug)
    else
        @debugv 1 "Activating test environment for `$proj_file`"
        return Pkg.activate(proj_file) do
            TestEnv.activate() do
                _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, testitem_timeout, verbose, debug)
            end
        end
    end
end

function _runtests_in_current_env(shouldrun, paths, projectfile::String, nworkers::Int, nworker_threads, testitem_timeout::Real, verbose::Bool, debug::Int)
    start_time = time()
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    @info "Starting scan for test items in project = `$proj_name` at paths = `$paths`"
    inc_time = time()
    @debugv 1 "Including tests in $paths"
    testitems, _ = include_testfiles!(proj_name, projectfile, paths, shouldrun)
    ntestitems = length(testitems.testitems)
    @debugv 1 "Done including tests in $paths"
    test_proj = Base.active_project()
    @info "Finished scanning for test items in $(round(time() - inc_time, digits=2)) seconds. Scheduling $ntestitems tests on pid = $(Libc.getpid()) with $nworkers worker processes and $nworker_threads threads per worker"
    try
        if nworkers == 0
            # This is where we disable printing for the serial executor case.
            Test.TESTSET_PRINT_ENABLE[] = false
            ctx = TestContext(proj_name, ntestitems)
            # we use a single TestSetupModules
            ctx.setups_evaled = TestSetupModules()
            for (i, testitem) in enumerate(testitems.testitems)
                testitem.workerid[] = myid()
                testitem.eval_number[] = i
                res = runtestitem(testitem, ctx; verbose=verbose)
                ts = res.testset
                testitem.stats[] = res.stats
                print_errors_and_captured_logs(testitem, ts; verbose)
                report_empty_testsets(testitem, ts)
                testitem.testset[] = ts
            end
        else
            # spawn a task per worker to start and manage the lifetime of the worker
            wids = zeros(Int, nworkers)
            try
                # get starting test items for each worker
                starting = get_starting_testitems(testitems, nworkers)
                @sync for i = 1:nworkers
                    ti = starting[i]
                    @spawn begin
                        # Wrapping with the logger that was set before we eval'd any user code to
                        # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
                        with_logger(current_logger()) do
                            wid = start_and_manage_worker($test_proj, $proj_name, $testitems, $ti, $nworker_threads, $testitem_timeout, $verbose, $debug)
                            wids[$i] = wid
                        end
                    end
                end
            finally
                # terminate all workers, silencing the current noisy Distributed @async exceptions
                redirect_stdio(stdout=devnull, stderr=devnull) do
                    @sync for wid in wids
                        wid > 0 && @spawn terminate_worker($wid)
                    end
                end
                # we've seen issues w/ Distributed using atexit to terminate workers
                # so we remove the atexit hook that does this
                i = findfirst(==(Distributed.terminate_all_workers), Base.atexit_hooks)
                if i !== nothing
                    deleteat!(Base.atexit_hooks, i)
                end
            end
        end
        Test.TESTSET_PRINT_ENABLE[] = true # reenable printing so our `finish` prints
        # return testitems
        @info "Finished running $ntestitems tests in $(round(time() - start_time, digits=2)) seconds"
        Test.finish(testitems) # print summary of total passes/failures/errors
    finally
        Test.TESTSET_PRINT_ENABLE[] = true
        # Cleanup test setup logs
        foreach(rm, filter(endswith(".log"), readdir(RETESTITEMS_TEMP_FOLDER, join=true)))
    end
    return nothing
end

function terminate_worker(pid)
    @assert myid() == 1
    try
        @debugv 1 "Terminating worker pid = $pid"
        if pid in Distributed.workers() && haskey(Distributed.map_pid_wrkr, pid)
            w = Distributed.map_pid_wrkr[pid]
            @assert isa(w, Distributed.Worker)
            kill(w.config.process, Base.SIGKILL)
            sleep(0.1)
            i = 1
            while pid in Distributed.workers()
                sleep(0.1)
                i += 1
                if i > 100
                    @warn "Failed to kill worker after 10 seconds: $pid"
                    break
                end
            end
        end
    catch e
        @warn "Failed to kill worker: $pid" exception=(failed_to_kill, catch_backtrace())
    end
end

function start_worker(test_proj, proj_name, nworker_threads, ntestitems, verbose, debug)
    wid = only(addprocs(1; exeflags=`--threads=$nworker_threads`))
    remotecall_eval(Main, wid, :(using ReTestItems))
    # we create the RemoteChannel on the *worker* so that
    # if it crashes, our take! call throws the ProcessExitedException
    ch = RemoteChannel(() -> Channel{Any}(0), wid)
    @spawnat wid begin
        schedule_remote_testitems!(test_proj, proj_name, ntestitems, ch, verbose, debug)
    end
    return wid, ch
end

function start_and_manage_worker(test_proj, proj_name, testitems, testitem, nworker_threads, timeout, verbose, debug)
    ntestitems = length(testitems.testitems)
    wid, ch = start_worker(test_proj, proj_name, nworker_threads, ntestitems, verbose, debug)
    nretries = 0
    cond = Threads.Condition()
    while testitem !== nothing
        testitem.workerid[] = wid
        # unbuffered channel will block until worker takes
        put!(ch, testitem)
        try
            timer = Timer(timeout) do tm
                close(tm)
                ex = TimeoutException("Test item $(repr(testitem.name)) timed out after $timeout seconds")
                @lock cond notify(cond, ex; error=true)
            end
            errmon(@spawn begin
                _ch = $ch
                try
                    # unbuffered channel blocks until worker is done eval-ing and puts result
                    res = take!(_ch)::TestItemResult
                    isopen($timer) && @lock cond notify(cond, res)
                catch e
                    isopen($timer) && @lock cond notify(cond, e; error=true)
                end
            end)
            try
                # if we get a ProcessExitedException or TimeoutException
                # then wait will throw here and we fall through to the outer try-catch
                testitem_result = @lock cond wait(cond)
                ts = testitem_result.testset
                testitem.stats[] = testitem_result.stats
                testitem.testset[] = ts
                print_errors_and_captured_logs(testitem, ts; verbose)
                report_empty_testsets(testitem, ts)
                testitem = next_testitem(testitems, testitem.id[])
                nretries = 0
            finally
                close(timer)
            end
        catch e
            if e isa ProcessExitedException || e isa TimeoutException
                _print_captured_logs(DEFAULT_STDOUT[], testitem)
                if e isa TimeoutException
                    @warn "Worker $(wid) timed out evaluating test item named: $(repr(testitem.name)) afer $timeout seconds, starting a new worker and retrying"
                    terminate_worker(wid)
                end
                if nretries == 2
                    @warn "Worker $(wid) is the 3rd failure evaluating test item named: $(repr(testitem.name)); recording test error"
                    Test.TESTSET_PRINT_ENABLE[] = false
                    ts = DefaultTestSet(testitem.name; verbose)
                    err = ErrorException("test item named: $(repr(testitem.name)) crashed worker processes 3 times")
                    Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
                        Base.ExceptionStack([(exception=err, backtrace=Union{Ptr{Nothing}, Base.InterpreterIP}[])]),
                        LineNumberNode(testitem.line, testitem.file)))
                    try
                        Test.finish(ts)
                    catch e2
                        e2 isa TestSetException || rethrow()
                    end
                    record_testitem!(testitems, testitem.id[], ts)
                    testitem = next_testitem(testitems, testitem.id[])
                    Test.TESTSET_PRINT_ENABLE[] = true
                    nretries = 0
                elseif e isa ProcessExitedException
                    @warn "Worker $(wid) died evaluating test item named: $(repr(testitem.name)), starting a new worker and retrying"
                end
                nretries += 1
                wid, ch = start_worker(test_proj, proj_name, nworker_threads, ntestitems, verbose, debug)
                # now we loop back around and put testitem on our new channel
                continue
            end
            # we don't expect any other kind of error, so rethrow, which will propagate
            # back up to the main coordinator task and throw to the user
            rethrow()
        end
    end
    return wid
end

is_invalid_state(ex::Exception) = false
is_invalid_state(ex::InvalidStateException) = true
is_invalid_state(ex::RemoteException) = ex.captured.ex isa InvalidStateException

# Check if the file at `filepath` is a "test file"
# i.e. if it ends with one of the identifying suffixes
function is_test_file(filepath)
    return (
        endswith(filepath, "_test.jl" ) ||
        endswith(filepath, "_tests.jl") ||
        endswith(filepath, "-test.jl" ) ||
        endswith(filepath, "-tests.jl")
    )
end
function is_testsetup_file(filepath)
    return (
        endswith(filepath, "_testsetup.jl" ) ||
        endswith(filepath, "_testsetups.jl") ||
        endswith(filepath, "-testsetup.jl" ) ||
        endswith(filepath, "-testsetups.jl")
    )
end

# for each directory, kick off a recursive test-finding task
function include_testfiles!(project_name, projectfile, paths, shouldrun)
    project_root = dirname(projectfile)
    subproject_root = nothing  # don't recurse into directories with their own Project.toml.
    root_node = dir_node = DirNode(project_name; verbose=true)
    dir_nodes = Dict{String, DirNode}()
    # setups is populated in store_test_item_setup when we expand a @testsetup
    # we set it below in tls as __RE_TEST_SETUPS__ for each included file
    setups = Dict{Symbol, TestSetup}()
    @sync for dir in ("test", "src")
        dir_node = DirNode(dir; verbose=true)
        push!(root_node, dir_node)
        dir_nodes[dir] = dir_node
        for (root, _, files) in Base.walkdir(joinpath(project_root, dir))
            if subproject_root !== nothing && startswith(root, subproject_root)
                @debugv 1 "Skipping files in `$root` in subproject `$subproject_root`"
                continue
            elseif _project_file(root) !== nothing && abspath(_project_file(root)) != projectfile
                subproject_root = root
                continue
            end
            rpath = relpath(root, project_root)
            dir_node = DirNode(rpath; verbose=true)
            dir_nodes[rpath] = dir_node
            push!(get(dir_nodes, dirname(rpath), root_node), dir_node)
            for file in files
                filepath = joinpath(root, file)
                # We filter here, rather than the tesitem level, to make sure we don't
                # `include` a file that isn't supposed to be a test-file at all, e.g. its
                # not on a path the user requested but it happens to have a test-file suffix.
                # We always include testsetup-files so users don't need to request them,
                # even if they're not in a requested path, e.g. they are a level up in the
                # directory tree. The testsetup-file suffix is hopefully specific enough
                # to ReTestItems that this doesn't lead to `include`ing unexpected files.
                if !(is_testsetup_file(filepath) || (is_test_file(filepath) && is_requested(filepath, paths)))
                    continue
                end
                fpath = relpath(filepath, project_root)
                file_node = FileNode(fpath, shouldrun; verbose=true)
                push!(dir_node, file_node)
                @debugv 1 "Including test items from file `$filepath`"
                @spawn begin
                    task_local_storage(:__RE_TEST_RUNNING__, true) do
                        task_local_storage(:__RE_TEST_ITEMS__, $file_node) do
                            task_local_storage(:__RE_TEST_PROJECT__, $(project_root)) do
                                task_local_storage(:__RE_TEST_SETUPS__, $setups) do
                                    Base.include(Main, $filepath)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    # finished including all test files, so finalize our graph
    # prune empty directories/files
    prune!(root_node)
    ti = TestItems(root_node)
    flatten_testitems!(ti)
    for (i, x) in enumerate(ti.testitems)
        # set id for each testitem
        x.id[] = i
        # populate testsetups for each testitem
        for s in x.setups
            if haskey(setups, s)
                push!(x.testsetups, setups[s])
            end
        end
    end
    return ti, setups # only returned for testing
end

# Is filepath one of the paths the user requested?
is_requested(filepath, paths::Tuple{}) = true  # no paths means no restrictions
function is_requested(filepath, paths::Tuple)
    return any(paths) do p
        startswith(filepath, abspath(p))
    end
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

function schedule_remote_testitems!(proj, proj_name, ntestitems, ch, verbose, debug)
    Pkg.activate(proj) do
        Test.TESTSET_PRINT_ENABLE[] = false
        # on remote workers, we need a per-worker TestSetupModules
        ctx = TestContext(proj_name, ntestitems)
        ctx.setups_evaled = TestSetupModules()
        @info "Starting test item evaluations for $proj_name on pid = $(Libc.getpid()), worker id = $(myid())), with $(Threads.nthreads()) threads"
        if debug > 0
            LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=debug) do
                schedule_testitems!(ctx, ch, verbose)
            end
        else
            schedule_testitems!(ctx, ch, verbose)
        end
    end
end

function schedule_testitems!(ctx::TestContext, ch, verbose::Bool)
    while true
        try
            ti = take!(ch)
            @debugv 2 "Scheduling test item$(_on_worker()): $(repr(ti.name)) from $(ti.file):$(ti.line)"
            ti_result = runtestitem(ti, ctx; verbose=verbose)
            put!(ch, ti_result)
            !isopen(ch) && !isready(ch) && break
        catch ex
            if !isopen(ch) && is_invalid_state(ex)
                break
            else
                rethrow()
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
        isassigned(ts.logstore) && close(ts.logstore[])
        ts.logstore[] = open(logpath(ts), "w")
        mod_expr = :(module $(gensym(ts.name)) end)
        # replace the module expr body with our @testsetup code
        mod_expr.args[3] = ts.code
        newmod = _capture_logs(ts) do
            with_source_path(() -> Core.eval(Main, mod_expr), ts.file)
        end
        # add the new module to our TestSetupModules
        mods.modules[setup] = newmod
        return nameof(newmod)
    end
end

# convenience method/globals for testing
const GLOBAL_TEST_CONTEXT_FOR_TESTING = TestContext("ReTestItems", 0)
const GLOBAL_TEST_SETUPS_FOR_TESTING = Dict{Symbol, TestSetup}()

# assumes any required setups were expanded outside of a runtests context
function runtestitem(ti::TestItem; kw...)
    # make a fresh TestSetupModules for each testitem run
    GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_evaled = TestSetupModules()
    empty!(ti.testsetups)
    for setup in ti.setups
        ts = get(GLOBAL_TEST_SETUPS_FOR_TESTING, setup, nothing)
        ts !== nothing && push!(ti.testsetups, ts)
    end
    runtestitem(ti, GLOBAL_TEST_CONTEXT_FOR_TESTING; kw...)
end

struct TimeoutException <: Exception
    msg::String
end

function runtestitem(ti::TestItem, ctx::TestContext; verbose::Bool=false, finish_test::Bool=true)
    name = ti.name
    log_running(ti, ctx.ntestitems)
    ts = DefaultTestSet(name; verbose=verbose)
    stats = (value=nothing, time=0.0, bytes=0, gctime=0.0, gcstats=Base.GC_Diff(0, 0, 0, 0, 0, 0, 0, 0, 0))
    # start with empty block expr and build up our @testitem module body
    body = Expr(:block)
    if ti.default_imports
        push!(body.args, :(using Test))
        if !isempty(ctx.projectname)
            # this obviously assumes we're in an environment where projectname is reachable
            push!(body.args, :(Base.@lock Base.require_lock using $(Symbol(ctx.projectname))))
        end
    end
    Test.push_testset(ts)
    try
        for setup in ti.setups
            # TODO(nhd): Consider implementing some affinity to setups, so that we can
            # prefer to send testitems to the workers that have already eval'd setups.
            # Or maybe allow user-configurable grouping of test items by worker?
            # Or group them by file by default?

            # ensure setup has been evaled before
            @debugv 1 "Ensuring setup for test item $(repr(name)) $(setup)$(_on_worker())."
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
        # we're being a bit sneaky here by calling softscope on each top-level body expr
        # which has the effect of test item body acting like you're at the REPL or
        # inside a testset, except imports/using/etc all still work as expected
        # more info: https://docs.julialang.org/en/v1.10-dev/manual/variables-and-scoping/#on-soft-scope
        for i = 1:length(body.args)
            body.args[i] = softscope(body.args[i])
        end
        mod_expr.args[3] = body
        # eval the testitem into a temporary module, so that all results can be GC'd
        # once the test is done and sent over the wire. (However, note that anonymous modules
        # aren't always GC'd right now: https://github.com/JuliaLang/julia/issues/48711)
        @debugv 1 "Evaluating test item $(repr(name))$(_on_worker())."
        # disabled for now since there were issues when tests tried serialize/deserialize
        # with things defined in an anonymous module
        # environment = Module()
        stats = @timed _capture_logs(ti) do
            with_source_path(() -> Core.eval(Main, mod_expr), ti.file)
            nothing # return nothing for stats.value
        end
        @debugv 1 "Test item $(repr(name)) done$(_on_worker())."
    catch err
        err isa InterruptException && rethrow()
        # Handle exceptions thrown outside a `@test` in the body of the @testitem:
        # Copied from Test.@testset's catch block:
        Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
            (Test.Base).current_exceptions(),
            LineNumberNode(ti.line, ti.file)))
    finally
        # Make sure all test setup logs are commited to file
        foreach(ts->isassigned(ts.logstore) && flush(ts.logstore[]), ti.testsetups)
        ts1 = Test.pop_testset()
        @assert ts1 === ts
        try
            finish_test && Test.finish(ts) # This will throw an exception if any of the tests failed.
        catch e
            e isa TestSetException || rethrow()
        end
    end
    @debugv 1 "Test item $(repr(name)) done$(_on_worker())."
    ti.stats[] = stats
    log_finished(ti, ctx.ntestitems)
    return TestItemResult(convert_results_to_be_transferrable(ts), stats)
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
