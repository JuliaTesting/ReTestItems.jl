module ReTestItems

using Base: @lock
using Dates: DateTime, ISODateTimeFormat, format, now, unix2datetime
using Test: Test, DefaultTestSet, TestSetException
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
const DEFAULT_RETRIES = 0

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

include("workers.jl")
using .Workers
include("macros.jl")
include("junit_xml.jl")
include("testcontext.jl")
include("log_capture.jl")

function __init__()
    DEFAULT_STDOUT[] = stdout
    DEFAULT_STDERR[] = stderr
    DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
    DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
    return nothing
end

struct TimeoutException <: Exception
    msg::String
end

_is_good_nthread_str(str) = occursin(r"^(auto|[1-9]\d{0,4})$", str)
_validated_nworker_threads(n::Int) = n > 0 ? string(n) : throw(ArgumentError("Invalid value for `nworker_threads` : $n"))
function _validated_nworker_threads(str)
    isok = true
    if isdefined(Threads, :nthreadpools)
        if ',' in str
            t1, t2 = split(str, ',', limit=2, keepempty=true)
            isok &= _is_good_nthread_str(t1) && _is_good_nthread_str(t2)
            if isok
                str = string(t1 == "auto" ? string(Sys.CPU_THREADS) : t1, ',', t2 == "auto" ? 1 : t2)
            end
        else
            isok &= _is_good_nthread_str(str)
        end
    else
        isok &= _is_good_nthread_str(str)
    end
    isok || throw(ArgumentError("Invalid value for `nworker_threads` : $str"))
    return replace(str, "auto" => string(Sys.CPU_THREADS))
end

"""
    ReTestItems.runtests()
    ReTestItems.runtests(mod::Module)
    ReTestItems.runtests(paths::AbstractString...)

Execute `@testitem` tests.

Only files ending in `_test.jl` or `_tests.jl` will be searched for test items.

If directory or file paths are passed, only those directories and files are searched.
If no arguments are passed, the `src/` and `test/` directories of the current project are
searched for `@testitem`s.

# Keywords

## Filtering `@testitem`s
- `name::Union{Regex,AbstractString,Nothing}=nothing`: Used to filter `@testitem`s by their name.
  `AbstractString` input will only keep the `@testitem` that exactly matches `name`,
  `Regex` can be used to partially match multiple `@testitem`s. By default, no filtering is
  applied.
- `tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing`: Used to filter `@testitem`s by their tags.
  A single tag can be used to match any `@testitem` that contains it, when multiple tags
  are provided, only `@testitem`s that contain _all_ of the tags will be run.
  By default, no filtering is applied.

`name` and `tags` filters are applied together and only those `@testitem`s that pass both filters
will be run.

## Configuring `runtests`
- `testitem_timeout::Int`: The number of seconds to wait until a `@testitem` is marked as failed.
  Defaults to 30 minutes. Note timeouts are currently only applied when `nworkers > 0`.
- `retries::Int=$DEFAULT_RETRIES`: The number of times to retry a `@testitem` if either tests
  do not pass or, if running with multiple workers, the worker fails or hits the `testitem_timeout`
  while running the tests. Can also be set using the `RETESTITEMS_RETRIES` environment variable.
  If a `@testitem` sets its own `retries` keyword, then the maximum of these two retry numbers
  will be used as the retry limit for that `@testitem`. When `report=true`, the report will
  contain information for all runs of a `@testitem` that was retried.
- `nworkers::Int`: The number of workers to use for running `@testitem`s. Default 0. Can also be set
  using the `RETESTITEMS_NWORKERS` environment variable.
- `nworker_threads::Union{String,Int}`: The number of threads to use for each worker. Defaults to 2.
  Can also be set using the `RETESTITEMS_NWORKER_THREADS` environment variable. Interactive threads are
  supported through a string (e.g. "auto,2").
- `worker_init_expr::Expr`: an expression that will be evaluated on each worker before any tests are run.
  Can be used to load packages or set up the environment. Must be a `:block` expression.
- `report::Bool=false`: If `true`, write a JUnit-format XML file summarising the test results.
  Can also be set using the `RETESTITEMS_REPORT` environment variable. The location at which
  the XML report is saved can be set using the `RETESTITEMS_REPORT_LOCATION` environment variable.
  By default the report will be written at the root of the project being tested.
- `logs::Symbol`: Handles how and when we display messages produced during test evaluation.
  Can be one of:
  - `:eager`: Everything is printed to `stdout` immediately, like in a regular Julia session.
  - `:batched`: Logs are saved to a file and then printed when the test item is finished.
  - `:issues`: Logs are saved to a file and only printed if there were any errors or failures.
  For interative sessions, `:eager` is the default when running with 0 or 1 workers, `:batched` otherwise.
  For non-interactive sessions, `:issues` is used by default.
- `verbose_results::Bool`: If `true`, the final test report will test each `@testset`, otherwise
    the results are aggregated on the `@testitem` level. Default is `false` for non-interactive sessions
    or when `logs=:issues`, `true` otherwise.
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
    nworker_threads::Union{Int,String}=get(ENV, "RETESTITEMS_NWORKER_THREADS", "2"),
    worker_init_expr::Expr=Expr(:block),
    testitem_timeout::Real=DEFAULT_TEST_ITEM_TIMEOUT,
    retries::Int=parse(Int, get(ENV, "RETESTITEMS_RETRIES", string(DEFAULT_RETRIES))),
    debug=0,
    name::Union{Regex,AbstractString,Nothing}=nothing,
    tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing,
    report::Bool=parse(Bool, get(ENV, "RETESTITEMS_REPORT", "false")),
    logs::Symbol=default_log_display_mode(report, nworkers),
    verbose_results::Bool=logs!=:issues && isinteractive(),
)
    nworker_threads = _validated_nworker_threads(nworker_threads)
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
    logs in LOG_DISPLAY_MODES || throw(ArgumentError("`logs` must be one of $LOG_DISPLAY_MODES, got $(repr(logs))"))
    report && logs == :eager && throw(ArgumentError("`report=true` is not compatible with `logs=:eager`"))
    # If we were given paths but none were valid, then nothing to run.
    !isempty(paths) && isempty(paths′) && return nothing
    shouldrun_combined(ti) = shouldrun(ti) && _shouldrun(name, ti.name) && _shouldrun(tags, ti.tags)
    mkpath(RETESTITEMS_TEMP_FOLDER) # ensure our folder wasn't removed
    save_current_stdio()
    nworkers = max(0, nworkers)
    retries = max(0, retries)
    debuglvl = Int(debug)
    if debuglvl > 0
        LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=debuglvl) do
            _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, worker_init_expr, testitem_timeout, retries, verbose_results, debuglvl, report, logs)
        end
    else
        return _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, worker_init_expr, testitem_timeout, retries, verbose_results, debuglvl, report, logs)
    end
end

# keep track of temporary test environments we create in case we can reuse them
# on repeated runs of `runtests` in the same Project
# in https://relationalai.atlassian.net/browse/RAI-11599, it was noted that when
# runtests was called at the REPL where Revise was already loaded, then source
# code was changed, then `runtests` was called again, a new temp test env was
# created on the 2nd call and precompilation happened because a source code change
# was detected, even though Revise already picks up the changes at the REPL.
# By tracking and reusing test environments, we can avoid this issue.
const TEST_ENVS = Dict{String, String}()

function _runtests(shouldrun, paths, nworkers::Int, nworker_threads::String, worker_init_expr::Expr, testitem_timeout::Real, retries::Int, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol)
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
    # Wrapping with the logger that was set before eval'ing any user code to
    # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
    with_logger(current_logger()) do
        if is_running_test_runtests_jl(proj_file)
            # Assume this is `Pkg.test`, so test env already active.
            @debugv 2 "Running in current environment `$(Base.active_project())`"
            return _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, worker_init_expr, testitem_timeout, retries, verbose_results, debug, report, logs)
        else
            @debugv 1 "Activating test environment for `$proj_file`"
            orig_proj = Base.active_project()
            try
                if haskey(TEST_ENVS, proj_file) && isfile(TEST_ENVS[proj_file])
                    testenv = TEST_ENVS[proj_file]
                    Base.set_active_project(testenv)
                else
                    Pkg.activate(proj_file)
                    testenv = TestEnv.activate()
                    TEST_ENVS[proj_file] = testenv
                end
                _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, worker_init_expr, testitem_timeout, retries, verbose_results, debug, report, logs)
            finally
                Base.set_active_project(orig_proj)
            end
        end
    end
end

function _runtests_in_current_env(
    shouldrun, paths, projectfile::String, nworkers::Int, nworker_threads, worker_init_expr::Expr,
    testitem_timeout::Real, retries::Int, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol,
)
    start_time = time()
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    @info "Scanning for test items in project `$proj_name` at paths: $(join(paths, ", "))"
    inc_time = time()
    @debugv 1 "Including tests in $paths"
    testitems, _ = include_testfiles!(proj_name, projectfile, paths, shouldrun, report)
    ntestitems = length(testitems.testitems)
    @debugv 1 "Done including tests in $paths"
    @info "Finished scanning for test items in $(round(time() - inc_time, digits=2)) seconds." *
        " Scheduling $ntestitems tests on pid $(Libc.getpid())" *
        (nworkers == 0 ? "" : " with $nworkers worker processes and $nworker_threads threads per worker.")
    try
        if nworkers == 0
            # This is where we disable printing for the serial executor case.
            Test.TESTSET_PRINT_ENABLE[] = false
            ctx = TestContext(proj_name, ntestitems)
            # we use a single TestSetupModules
            ctx.setups_evaled = TestSetupModules()
            for (i, testitem) in enumerate(testitems.testitems)
                testitem.workerid[] = Libc.getpid()
                testitem.eval_number[] = i
                nretries = 0
                retry_limit = max(retries, testitem.retries)
                while nretries ≤ retry_limit
                    res = runtestitem(testitem, ctx; verbose_results, logs)
                    ts = res.testset
                    print_errors_and_captured_logs(testitem, nretries + 1; logs)
                    report_empty_testsets(testitem, ts)
                    if ts.anynonpass && nretries < retry_limit
                        nretries += 1
                        @warn "Test item $(repr(testitem.name)) failed. Retrying. Retry=$nretries."
                    else
                        if nretries > 0
                            @info "Test item $(repr(testitem.name)) passed on retry $nretries."
                        end
                        break
                    end
                end
            end
        elseif !isempty(testitems.testitems)
            # spawn a task per worker to start and manage the lifetime of the worker
            # get starting test items for each worker
            starting = get_starting_testitems(testitems, nworkers)
            @sync for i = 1:nworkers
                ti = starting[i]
                @spawn begin
                    # Wrapping with the logger that was set before we eval'd any user code to
                    # avoid world age issues when logging https://github.com/JuliaLang/julia/issues/33865
                    with_logger(current_logger()) do
                        start_and_manage_worker($proj_name, $testitems, $ti, $nworker_threads, $worker_init_expr, $testitem_timeout, $retries, $verbose_results, $debug, $report, $logs)
                    end
                end
            end
        end
        Test.TESTSET_PRINT_ENABLE[] = true # reenable printing so our `finish` prints
        record_results!(testitems)
        report && write_junit_file(proj_name, dirname(projectfile), testitems.graph.junit)
        Test.finish(testitems) # print summary of total passes/failures/errors
    finally
        Test.TESTSET_PRINT_ENABLE[] = true
        # Cleanup test setup logs
        foreach(rm, filter(endswith(".log"), readdir(RETESTITEMS_TEMP_FOLDER, join=true)))
    end
    return nothing
end

function start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems)
    w = Worker(; threads="$nworker_threads")
    # remote_fetch here because we want to make sure the worker is all setup before starting to eval testitems
    remote_fetch(w, quote
        using ReTestItems, Test
        Test.TESTSET_PRINT_ENABLE[] = false
        const GLOBAL_TEST_CONTEXT = ReTestItems.TestContext($proj_name, $ntestitems)
        GLOBAL_TEST_CONTEXT.setups_evaled = ReTestItems.TestSetupModules()
        @info "Starting test item evaluations on pid = $(Libc.getpid()), with $(Threads.nthreads()) threads"
        $(worker_init_expr.args...)
        nothing
    end)
    return w
end


# This is only used to signal that we need to retry. We don't use Test.TestSetException as
# that requires information that we are not going to use anyway.
struct TestSetFailure <: Exception end
throw_if_failed(ts) = ts.anynonpass ? throw(TestSetFailure()) : nothing

function record_test_error!(testitem, ntries)
    Test.TESTSET_PRINT_ENABLE[] = false
    ts = DefaultTestSet(testitem.name)
    err = ErrorException("test item $(repr(testitem.name)) didn't succeed after $ntries tries")
    Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
        Base.ExceptionStack([(exception=err, backtrace=Union{Ptr{Nothing}, Base.InterpreterIP}[])]),
        LineNumberNode(testitem.line, testitem.file)))
    try
        Test.finish(ts)
    catch e2
        e2 isa TestSetException || rethrow()
    end
    Test.TESTSET_PRINT_ENABLE[] = true
    push!(testitem.testsets, ts)
    push!(testitem.stats, PerfStats())  # No data since testitem didn't complete
    return testitem
end

function start_and_manage_worker(
    proj_name, testitems, testitem, nworker_threads, worker_init_expr,
    timeout::Real, retries::Int, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol
)
    ntestitems = length(testitems.testitems)
    worker = start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems)
    nretries = 0
    cond = Threads.Condition()
    while testitem !== nothing
        testitem.workerid[] = worker.pid
        fut = remote_eval(worker, :(ReTestItems.runtestitem($testitem, GLOBAL_TEST_CONTEXT; verbose_results=$verbose_results, logs=$(QuoteNode(logs)))))
        retry_limit = max(retries, testitem.retries)
        try
            timer = Timer(timeout) do tm
                close(tm)
                ex = TimeoutException("Test item $(repr(testitem.name)) timed out after $timeout seconds")
                @lock cond notify(cond, ex; error=true)
            end
            errmon(@spawn begin
                _fut = $fut
                try
                    # Future blocks until worker is done eval-ing and returns result
                    res = fetch(_fut)::TestItemResult
                    isopen($timer) && @lock cond notify(cond, res)
                catch e
                    isopen($timer) && @lock cond notify(cond, e; error=true)
                end
            end)
            try
                # if we get a WorkerTerminatedException or TimeoutException
                # then wait will throw here and we fall through to the outer try-catch
                @debugv 2 "Waiting on test item result"
                testitem_result = @lock cond wait(cond)
                @debugv 2 "Recieved test item result"
                ts = testitem_result.testset
                push!(testitem.testsets, ts)
                push!(testitem.stats, testitem_result.stats)
                print_errors_and_captured_logs(testitem, nretries + 1; logs)
                report_empty_testsets(testitem, ts)
                # if the result isn't a pass, we throw to go to the outer try-catch
                throw_if_failed(ts)
                testitem = next_testitem(testitems, testitem.id[])
                nretries = 0
            finally
                close(timer)
            end
        catch e
            @debugv 2 "Error" exception=e
            if !(e isa WorkerTerminatedException || e isa TimeoutException || e isa TestSetFailure)
                # we don't expect any other kind of error, so rethrow, which will propagate
                # back up to the main coordinator task and throw to the user
                rethrow()
            end

            if !(e isa TestSetFailure)
                println(DEFAULT_STDOUT[])
                # Explicitly show captured logs or say there weren't any in case we're about
                # to terminte the worker
                _print_captured_logs(DEFAULT_STDOUT[], testitem, nretries + 1)
            end

            if e isa TimeoutException
                @debugv 1 "Test item $(repr(testitem.name)) timed out. Terminating worker $worker"
                terminate!(worker)
                wait(worker)
            end
            if nretries == retry_limit
                if e isa TimeoutException
                    @warn "$worker timed out evaluating test item $(repr(testitem.name)) afer $timeout seconds. \
                        Recording test error, and starting a new worker."
                    record_test_error!(testitem, nretries + 1)
                elseif e isa WorkerTerminatedException
                    @warn "$worker died evaluating test item $(repr(testitem.name)). \
                        Recording test error, and starting a new worker."
                    record_test_error!(testitem, nretries + 1)
                else
                    @assert e isa TestSetFailure
                    # We already printed the error and recorded the testset.
                end
                testitem = next_testitem(testitems, testitem.id[])
                nretries = 0
            else
                nretries += 1
                if e isa TimeoutException
                    @warn "$worker timed out evaluating test item $(repr(testitem.name)) afer $timeout seconds. \
                        Starting a new worker and retrying. Retry=$nretries."
                elseif e isa WorkerTerminatedException
                    @warn "$worker died evaluating test item $(repr(testitem.name)). \
                        Starting a new worker and retrying. Retry=$nretries."
                else
                    @assert e isa TestSetFailure
                    @warn "Test item $(repr(testitem.name)) failed. Retrying on $worker. Retry=$nretries."
                end
            end
            if (e isa TimeoutException || e isa WorkerTerminatedException)
                worker = start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems)
            end
            # now we loop back around to reschedule the testitem
            continue
        end
    end
    close(worker)
    return nothing
end

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

# is `dir` the root of a subproject inside the current project?
function _is_subproject(dir, current_projectfile)
    projectfile = _project_file(dir)
    isnothing(projectfile) && return false

    projectfile = abspath(projectfile)
    projectfile == current_projectfile && return false
    # a `test/Project.toml` is special and doesn't indicate a subproject
    current_project_dir = dirname(current_projectfile)
    rel_projectfile = relpath(projectfile, current_project_dir)
    rel_projectfile == joinpath("test", "Project.toml") && return false
    return true
end

# for each directory, kick off a recursive test-finding task
function include_testfiles!(project_name, projectfile, paths, shouldrun, report::Bool)
    project_root = dirname(projectfile)
    subproject_root = nothing  # don't recurse into directories with their own Project.toml.
    root_node = DirNode(project_name; report, verbose=true)
    dir_nodes = Dict{String, DirNode}()
    # setups is populated in store_test_item_setup when we expand a @testsetup
    # we set it below in tls as __RE_TEST_SETUPS__ for each included file
    setups = Dict{Symbol, TestSetup}()
    hidden_re = r"\.\w"
    @sync for (root, d, files) in Base.walkdir(project_root)
        if subproject_root !== nothing && startswith(root, subproject_root)
            @debugv 1 "Skipping files in `$root` in subproject `$subproject_root`"
            continue
        elseif _is_subproject(root, projectfile)
            subproject_root = root
            continue
        end
        rpath = relpath(root, project_root)
        startswith(rpath, hidden_re) && continue # skip hidden directories
        dir_node = DirNode(rpath; report, verbose=true)
        dir_nodes[rpath] = dir_node
        push!(get(dir_nodes, dirname(rpath), root_node), dir_node)
        for file in files
            startswith(file, hidden_re) && continue # skip hidden files
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
            file_node = FileNode(fpath, shouldrun; report, verbose=true)
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

function ensure_setup!(ctx::TestContext, setup::Symbol, setups::Vector{TestSetup}, logs::Symbol)
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
        newmod = _redirect_logs(logs == :eager ? DEFAULT_STDOUT[] : ts.logstore[]) do
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

function runtestitem(ti::TestItem, ctx::TestContext; verbose_results::Bool=false, finish_test::Bool=true, logs::Symbol=:eager)
    name = ti.name
    log_testitem_start(ti, ctx.ntestitems)
    ts = DefaultTestSet(name; verbose=verbose_results)
    stats = PerfStats()
    # start with empty block expr and build up our @testitem module body
    body = Expr(:block)
    if ti.default_imports
        push!(body.args, :(using Test))
        if !isempty(ctx.projectname)
            # this obviously assumes we're in an environment where projectname is reachable
            push!(body.args, :(using $(Symbol(ctx.projectname))))
        end
    end
    Test.push_testset(ts)
    # This allows us to identify if the code is running inside a `@testitem`, which is
    # useful for e.g. macros that behave differently conditional on being in a `@testitem`.
    # This was added so we could have a `@test_foo` macro exapnd to a `@testset` if already
    # in a `@testitem` and expand to an `@testitem` otherwise.
    prev = get(task_local_storage(), :__TESTITEM_ACTIVE__, false)
    task_local_storage()[:__TESTITEM_ACTIVE__] = true
    try
        for setup in ti.setups
            # TODO(nhd): Consider implementing some affinity to setups, so that we can
            # prefer to send testitems to the workers that have already eval'd setups.
            # Or maybe allow user-configurable grouping of test items by worker?
            # Or group them by file by default?

            # ensure setup has been evaled before
            @debugv 1 "Ensuring setup for test item $(repr(name)) $(setup)$(_on_worker())."
            ts_mod = ensure_setup!(ctx, setup, ti.testsetups, logs)
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
        _, stats = @timed_with_compilation _redirect_logs(logs == :eager ? DEFAULT_STDOUT[] : logpath(ti)) do
            with_source_path(() -> Core.eval(Main, mod_expr), ti.file)
            nothing # return nothing as the first return value of @timed_with_compilation
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
        task_local_storage()[:__TESTITEM_ACTIVE__] = prev
        @assert ts1 === ts
        try
            finish_test && Test.finish(ts) # This will throw an exception if any of the tests failed.
        catch e
            e isa TestSetException || rethrow()
        end
    end
    @debugv 1 "Test item $(repr(name)) done$(_on_worker())."
    push!(ti.testsets, ts)
    push!(ti.stats, stats)
    log_testitem_done(ti, ctx.ntestitems)
    # It takes 2 GCs to do a full mark+sweep (the first one is a partial mark, full sweep, the next one is a full mark)
    GC.gc(true)
    GC.gc(false)
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
