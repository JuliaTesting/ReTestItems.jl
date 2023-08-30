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
const DEFAULT_TESTITEM_TIMEOUT = 30*60
const DEFAULT_RETRIES = 0
const DEFAULT_MEMORY_THRESHOLD = 0.99

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

# Call softscope on each top-level body expr
# which has the effect of the body acting like you're at the REPL or
# inside a testset, except imports/using/etc all still work as expected
# more info: https://docs.julialang.org/en/v1.10-dev/manual/variables-and-scoping/#on-soft-scope
function softscope_all!(@nospecialize ex)
    for i = 1:length(ex.args)
        ex.args[i] = softscope(ex.args[i])
    end
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
- `testitem_timeout::Real`: The number of seconds to wait until a `@testitem` is marked as failed.
  Defaults to 30 minutes. Can also be set using the `RETESTITEMS_TESTITEM_TIMEOUT` environment variable.
  Note timeouts are currently only applied when `nworkers > 0`.
- `retries::Int=$DEFAULT_RETRIES`: The number of times to retry a `@testitem` if either tests
  do not pass or, if running with multiple worker processes, the worker fails or hits the `testitem_timeout`
  while running the tests. Can also be set using the `RETESTITEMS_RETRIES` environment variable.
  If a `@testitem` sets its own `retries` keyword, then the maximum of these two retry numbers
  will be used as the retry limit for that `@testitem`. When `report=true`, the report will
  contain information for all runs of a `@testitem` that was retried.
- `nworkers::Int`: The number of worker processes to use for running `@testitem`s. Default 0. Can also be set
  using the `RETESTITEMS_NWORKERS` environment variable.
- `nworker_threads::Union{String,Int}`: The number of threads to use for each worker process. Defaults to 2.
  Can also be set using the `RETESTITEMS_NWORKER_THREADS` environment variable. Interactive threads are
  supported through a string (e.g. "auto,2").
- `worker_init_expr::Expr`: an expression that will be evaluated on each worker process before any tests are run.
  Can be used to load packages or set up the environment. Must be a `:block` expression.
- `test_end_expr::Expr`: an expression that will be evaluated after each testitem is run.
  Can be used to verify that global state is unchanged after running a test. Must be a `:block` expression.
- `memory_threshold::Real`: Sets the fraction of memory that can be in use before a worker processes are
  restarted to free memory. Defaults to $DEFAULT_MEMORY_THRESHOLD. Only supported with `nworkers > 0`.
  For example, if set to 0.8, then when >80% of the available memory is in use, a worker process will be killed and
  replaced with a new worker before the next testitem is evaluated. The testitem will then be run on the new worker
  process, regardless of if memory pressure dropped below the threshold. If the memory pressure remains above the
  threshold, then a worker process will again be replaced before the next testitem is evaluated.
  Can also be set using the `RETESTITEMS_MEMORY_THRESHOLD` environment variable.
  **Note**: the `memory_threshold` keyword is experimental and may be removed in future versions.
- `report::Bool=false`: If `true`, write a JUnit-format XML file summarising the test results.
  Can also be set using the `RETESTITEMS_REPORT` environment variable. The location at which
  the XML report is saved can be set using the `RETESTITEMS_REPORT_LOCATION` environment variable.
  By default the report will be written at the root of the project being tested.
- `logs::Symbol`: Handles how and when we display messages produced during test evaluation.
  Can be one of:
  - `:eager`: Everything is printed to `stdout` immediately, like in a regular Julia session.
  - `:batched`: Logs are saved to a file and then printed when the test item is finished.
  - `:issues`: Logs are saved to a file and only printed if there were any errors or failures.
  For interative sessions, `:eager` is the default when running with 0 or 1 worker processes, `:batched` otherwise.
  For non-interactive sessions, `:issues` is used by default.
- `verbose_results::Bool`: If `true`, the final test report will list each `@testitem`, otherwise
    the results are aggregated. Default is `false` for non-interactive sessions
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
    testitem_timeout::Real=parse(Float64, get(ENV, "RETESTITEMS_TESTITEM_TIMEOUT", string(DEFAULT_TESTITEM_TIMEOUT))),
    retries::Int=parse(Int, get(ENV, "RETESTITEMS_RETRIES", string(DEFAULT_RETRIES))),
    memory_threshold::Real=parse(Float64, get(ENV, "RETESTITEMS_MEMORY_THRESHOLD", string(DEFAULT_MEMORY_THRESHOLD))),
    debug=0,
    name::Union{Regex,AbstractString,Nothing}=nothing,
    tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing,
    report::Bool=parse(Bool, get(ENV, "RETESTITEMS_REPORT", "false")),
    logs::Symbol=default_log_display_mode(report, nworkers),
    verbose_results::Bool=(logs !== :issues && isinteractive()),
    test_end_expr::Expr=Expr(:block),
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
    (0 ≤ memory_threshold ≤ 1) || throw(ArgumentError("`memory_threshold` must be between 0 and 1, got $(repr(memory_threshold))"))
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
            _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, retries, memory_threshold, verbose_results, debuglvl, report, logs)
        end
    else
        return _runtests(shouldrun_combined, paths′, nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, retries, memory_threshold, verbose_results, debuglvl, report, logs)
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

function _runtests(shouldrun, paths, nworkers::Int, nworker_threads::String, worker_init_expr::Expr, test_end_expr::Expr, testitem_timeout::Real, retries::Int, memory_threshold::Real, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol)
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
            return _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, retries, memory_threshold, verbose_results, debug, report, logs)
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
                _runtests_in_current_env(shouldrun, paths, proj_file, nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, retries, memory_threshold, verbose_results, debug, report, logs)
            finally
                Base.set_active_project(orig_proj)
            end
        end
    end
end

function _runtests_in_current_env(
    shouldrun, paths, projectfile::String, nworkers::Int, nworker_threads, worker_init_expr::Expr, test_end_expr::Expr,
    testitem_timeout::Real, retries::Int, memory_threshold::Real, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol,
)
    start_time = time()
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    @info "Scanning for test items in project `$proj_name` at paths: $(join(paths, ", "))"
    inc_time = time()
    @debugv 1 "Including tests in $paths"
    testitems, _ = include_testfiles!(proj_name, projectfile, paths, shouldrun, verbose_results, report)
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
                run_number = 1
                max_runs = 1 + max(retries, testitem.retries)
                while run_number ≤ max_runs
                    res = runtestitem(testitem, ctx; test_end_expr, verbose_results, logs)
                    ts = res.testset
                    print_errors_and_captured_logs(testitem, run_number; logs)
                    report_empty_testsets(testitem, ts)
                    # It takes 2 GCs to do a full mark+sweep
                    # (the first one is a partial mark, full sweep, the next one is a full mark).
                    GC.gc(true)
                    GC.gc(false)
                    if any_non_pass(ts) && run_number != max_runs
                        run_number += 1
                        @info "Retrying $(repr(testitem.name)). Run=$run_number."
                    else
                        break
                    end
                end
            end
        elseif !isempty(testitems.testitems)
            # Use the logger that was set before we eval'd any user code to avoid world age
            # issues when logging https://github.com/JuliaLang/julia/issues/33865
            original_logger = current_logger()
            # Wait for all workers to be started so we can throw as soon as possible if
            # we were unable to start the requested number of workers
            @info "Starting test workers"
            workers = Vector{Worker}(undef, nworkers)
            ntestitems = length(testitems.testitems)
            @sync for i in 1:nworkers
                @spawn begin
                    with_logger(original_logger) do
                        $workers[$i] = robust_start_worker($proj_name, $nworker_threads, $worker_init_expr, $ntestitems; worker_num=$i)
                    end
                end
            end
            # Now all workers are started, we can begin processing test items.
            @info "Starting evaluating test items"
            starting = get_starting_testitems(testitems, nworkers)
            @sync for (i, w) in enumerate(workers)
                ti = starting[i]
                @spawn begin
                    with_logger(original_logger) do
                        manage_worker($w, $proj_name, $testitems, $ti, $nworker_threads, $worker_init_expr, $test_end_expr, $testitem_timeout, $retries, $memory_threshold, $verbose_results, $debug, $report, $logs)
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

# Start a new `Worker` with `nworker_threads` threads and evaluate `worker_init_expr` on it.
# The provided `worker_num` is only for logging purposes, and not persisted as part of the worker.
function start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems; worker_num=nothing)
    w = Worker(; threads="$nworker_threads")
    i = worker_num == nothing ? "" : " $worker_num"
    # remote_fetch here because we want to make sure the worker is all setup before starting to eval testitems
    remote_fetch(w, quote
        using ReTestItems, Test
        Test.TESTSET_PRINT_ENABLE[] = false
        const GLOBAL_TEST_CONTEXT = ReTestItems.TestContext($proj_name, $ntestitems)
        GLOBAL_TEST_CONTEXT.setups_evaled = ReTestItems.TestSetupModules()
        @info "Starting test worker$($i) on pid = $(Libc.getpid()), with $(Threads.nthreads()) threads"
        $(worker_init_expr.args...)
        nothing
    end)
    return w
end

# Want to be somewhat robust to workers possibly terminating during start up (e.g. due to
# the `worker_init_expr`).
# The number of retries and delay between retries is currently arbitrary...
# we want to retry at least once, and we give a slight delay in case there are resources
# that need to be cleaned up before a new worker would be able to start successfully.
const _NRETRIES = 2
const _RETRY_DELAY_SECONDS = 1

# Start a worker, retrying up to `_NRETRIES` times if it terminates unexpectedly,
# with a delay of `_RETRY_DELAY_SECONDS` seconds between retries.
# If we fail to start a worker successfully after `_NRETRIES` retries, or if we somehow hit
# something other than a `WorkerTerminatedException`, then rethrow the exception.
function robust_start_worker(args...; kwargs...)
    f = retry(start_worker; delays=fill(_RETRY_DELAY_SECONDS, _NRETRIES), check=_worker_terminated)
    f(args...; kwargs...)
end

function _worker_terminated(state, exception)
    if exception isa WorkerTerminatedException
        retry_num = state - 1
        @error "$(exception.worker) terminated unexpectedly. Starting new worker process (retry $retry_num/$_NRETRIES)."
        return true
    else
        return false
    end
end

any_non_pass(ts::DefaultTestSet) = ts.anynonpass

function record_timeout!(testitem, run_number::Int, timeout_limit::Real)
    timeout_s = round(Int, timeout_limit)
    time_str = if timeout_s < 60
        string(timeout_s, "s")
    else
        mins, secs = divrem(timeout_s, 60)
        if iszero(secs)
            string(mins, "m")
        else
            string(mins, "m", lpad(secs, 2, "0"), "s")
        end
    end
    msg = "Timed out after $time_str evaluating test item $(repr(testitem.name)) (run=$run_number)"
    record_test_error!(testitem, msg, timeout_limit)
end

function record_worker_terminated!(testitem, worker::Worker, run_number::Int)
    termsignal = worker.process.termsignal
    msg = "Worker process aborted (signal=$termsignal) evaluating test item $(repr(testitem.name)) (run=$run_number)"
    record_test_error!(testitem, msg)
end

function record_test_error!(testitem, msg, elapsed_seconds::Real=0.0)
    Test.TESTSET_PRINT_ENABLE[] = false
    ts = DefaultTestSet(testitem.name)
    err = ErrorException(msg)
    Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
        Base.ExceptionStack([(exception=err, backtrace=Union{Ptr{Nothing}, Base.InterpreterIP}[])]),
        LineNumberNode(testitem.line, testitem.file)))
    try
        Test.finish(ts)
    catch e2
        e2 isa TestSetException || rethrow()
    end
    # Since we're manually constructing a TestSet here to report tests that already ran and
    # were killed, we need to manually set how long those tests were running (if known).
    ts.time_end = ts.time_start + elapsed_seconds
    Test.TESTSET_PRINT_ENABLE[] = true
    push!(testitem.testsets, ts)
    push!(testitem.stats, PerfStats())  # No data since testitem didn't complete
    return testitem
end

function manage_worker(
    worker::Worker, proj_name::AbstractString, testitems::TestItems, testitem::TestItem, nworker_threads, worker_init_expr::Expr, test_end_expr::Expr,
    timeout::Real, retries::Int, memory_threshold::Real, verbose_results::Bool, debug::Int, report::Bool, logs::Symbol
)
    ntestitems = length(testitems.testitems)
    run_number = 1
    memory_threshold_percent = 100*memory_threshold
    while testitem !== nothing
        ch = Channel{TestItemResult}(1)
        if memory_percent() > memory_threshold_percent
            @warn "Memory usage ($(Base.Ryu.writefixed(memory_percent(), 1))%) is higher than limit ($(Base.Ryu.writefixed(memory_threshold_percent, 1))%). Restarting worker process to try to free memory."
            terminate!(worker)
            wait(worker)
            worker = robust_start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems)
        end
        testitem.workerid[] = worker.pid
        fut = remote_eval(worker, :(ReTestItems.runtestitem($testitem, GLOBAL_TEST_CONTEXT; test_end_expr=$(QuoteNode(test_end_expr)), verbose_results=$verbose_results, logs=$(QuoteNode(logs)))))
        max_runs = 1 + max(retries, testitem.retries)
        try
            timer = Timer(timeout) do tm
                close(tm)
                ex = TimeoutException("Test item $(repr(testitem.name)) timed out after $timeout seconds")
                close(ch, ex)
            end
            errmon(@spawn begin
                _fut = $fut
                try
                    # Future blocks until worker is done eval-ing and returns result
                    res = fetch(_fut)::TestItemResult
                    isopen($timer) && put!(ch, res)
                catch e
                    isopen($timer) && close(ch, e)
                end
            end)
            try
                # if we get a WorkerTerminatedException or TimeoutException
                # then wait will throw here and we fall through to the outer try-catch
                @debugv 2 "Waiting on result for test item $(repr(testitem.name))"
                testitem_result = take!(ch)
                @debugv 2 "Received result for test item $(repr(testitem.name))"
                ts = testitem_result.testset
                push!(testitem.testsets, ts)
                push!(testitem.stats, testitem_result.stats)
                print_errors_and_captured_logs(testitem, run_number; logs)
                report_empty_testsets(testitem, ts)
                # Run GC to free memory on the worker before next testitem.
                @debugv 2 "Running GC on $worker"
                remote_fetch(worker, :(GC.gc(true); GC.gc(false)))
                if any_non_pass(ts) && run_number != max_runs
                    run_number += 1
                    @info "Retrying $(repr(testitem.name)) on $worker. Run=$run_number."
                else
                    testitem = next_testitem(testitems, testitem.number[])
                    run_number = 1
                end
            finally
                close(timer)
            end
        catch e
            @debugv 2 "Error" exception=e
            println(DEFAULT_STDOUT[])
            _print_captured_logs(DEFAULT_STDOUT[], testitem, run_number)
            # Handle the exception
            if e isa TimeoutException
                @debugv 1 "Test item $(repr(testitem.name)) timed out. Terminating worker $worker"
                terminate!(worker)
                wait(worker)
                @error "$worker timed out evaluating test item $(repr(testitem.name)) after $timeout seconds. \
                    Recording test error."
                record_timeout!(testitem, run_number, timeout)
            elseif e isa WorkerTerminatedException
                @error "$worker died evaluating test item $(repr(testitem.name)). \
                    Recording test error."
                record_worker_terminated!(testitem, worker, run_number)
            else
                # We don't expect any other kind of error, so rethrow, which will propagate
                # back up to the main coordinator task and throw to the user
                rethrow()
            end
            # Handle retries
            if run_number == max_runs
                testitem = next_testitem(testitems, testitem.number[])
                run_number = 1
            else
                run_number += 1
                @info "Retrying $(repr(testitem.name)) on a new worker process. Run=$run_number."
            end
            # The worker was terminated, so replace it unless there are no more testitems to run
            if testitem !== nothing
                worker = robust_start_worker(proj_name, nworker_threads, worker_init_expr, ntestitems)
            end
            # Now loop back around to reschedule the testitem
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

# Error if we are trying to `include` a file with anything except an `@testitem` or
# `@testsetup` call at the top-level.
# Re-use `Base.include` to avoid duplicating subtle code-loading logic from `Base`.
# Note:
#   For now this is just checks for `:macrocall` so we can support alternative macros that
#   expand to be an `@testitem`. We will likely _tighten_ this check in future.
#   i.e. We may in future throw an error for files that currently successfully get included.
#   i.e. Only `@testitem` and `@testsetup` calls are officially supported.
checked_include(mod, filepath) = Base.include(check_retestitem_macrocall, mod, filepath)
function check_retestitem_macrocall(expr)
    is_retestitem_macrocall(expr) || _throw_not_macrocall(expr)
    return expr
end
function is_retestitem_macrocall(expr::Expr)
    if expr.head == :macrocall
        # For now, we're not checking for `@testitem`/`@testsetup` only,
        # but we can still guard against the most common issue.
        name = expr.args[1]
        if name != Symbol("@testset") && name != Symbol("@test")
            return true
        end
    end
    return false
end
function _throw_not_macrocall(expr)
    # `Base.include` sets the `:SOURCE_PATH` before the `mapexpr`
    # (`check_retestitem_macrocall`) is first called
    file = get(task_local_storage(), :SOURCE_PATH, "unknown")
    msg = """
    Test files must only include `@testitem` and `@testsetup` calls.
    In $(repr(file)) got:
        $(Base.remove_linenums!(expr))
    """
    error(msg)
end

# for each directory, kick off a recursive test-finding task
function include_testfiles!(project_name, projectfile, paths, shouldrun, verbose_results::Bool, report::Bool)
    project_root = dirname(projectfile)
    subproject_root = nothing  # don't recurse into directories with their own Project.toml.
    root_node = DirNode(project_name; report, verbose=verbose_results)
    dir_nodes = Dict{String, DirNode}()
    # setup_channel is populated in store_test_setup when we expand a @testsetup
    # we set it below in tls as __RE_TEST_SETUPS__ for each included file
    setup_channel = Channel{Pair{Symbol, TestSetup}}(Inf)
    setup_task = @spawn begin
        setups = Dict{Symbol, TestSetup}()
        for (name, setup) in setup_channel
            if haskey(setups, name)
                @warn "Encountered duplicate @testsetup with name: `$name`. Replacing..."
            end
            setups[name] = setup
        end
        return setups
    end
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
        dir_node = DirNode(rpath; report, verbose=verbose_results)
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
            file_node = FileNode(fpath, shouldrun; report, verbose=verbose_results)
            testitem_names = Set{String}() # to enforce that names in the same file are unique
            push!(dir_node, file_node)
            @debugv 1 "Including test items from file `$filepath`"
            @spawn begin
                task_local_storage(:__RE_TEST_RUNNING__, true) do
                    task_local_storage(:__RE_TEST_ITEMS__, ($file_node, $testitem_names)) do
                        task_local_storage(:__RE_TEST_PROJECT__, $(project_root)) do
                            task_local_storage(:__RE_TEST_SETUPS__, $setup_channel) do
                                checked_include(Main, $filepath)
                            end
                        end
                    end
                end
            end
        end
    end
    @debugv 2 "Finished including files"
    # finished including all test files, so finalize our graph
    # prune empty directories/files
    close(setup_channel)
    prune!(root_node)
    ti = TestItems(root_node)
    flatten_testitems!(ti)
    check_ids(ti.testitems)
    setups = fetch(setup_task)
    for (i, x) in enumerate(ti.testitems)
        # set a unique number for each testitem
        x.number[] = i
        # populate testsetups for each testitem
        for s in x.setups
            if haskey(setups, s)
                push!(x.testsetups, setups[s])
            end
        end
    end
    return ti, setups # only returned for testing
end

function check_ids(testitems)
    ids = getproperty.(testitems, :id)
    # This should only be possible to trip if users are manually passing the `_id` keyword.
    allunique(ids) || _throw_duplicate_ids(testitems)
    return nothing
end

# Try to give an informative error, so users can correct the issue.
function _throw_duplicate_ids(testitems)
    seen = Dict{String,String}()
    for ti in testitems
        id = ti.id
        source = string(relpath(ti.file, ti.project_root), ":", ti.line)
        name = string(repr(ti.name), " at ", source)
        if haskey(seen, id)
            name1 = seen[id]
            error("Test item IDs must be unique. ID `$id` used for test items: $name1 and $name")
        else
            seen[id] = name
        end
    end
    # This should be unreachable, since the loop above should always find a duplicate.
    error("Test item IDs must be unique")
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

# Default to verbose output for running an individual test-item by itself, i.e.
# when `runtestitem` called directly or `@testitem` called outside of `runtests`.
function runtestitem(
    ti::TestItem, ctx::TestContext;
    test_end_expr::Expr=Expr(:block), logs::Symbol=:eager, verbose_results::Bool=true, finish_test::Bool=true,
)
    name = ti.name
    log_testitem_start(ti, ctx.ntestitems)
    ts = DefaultTestSet(name; verbose=verbose_results)
    stats = PerfStats()
    # start with empty block expr and build up our `@testitem` and `test_end_expr` module bodies
    body = Expr(:block)
    test_end_body = Expr(:block)
    if ti.default_imports
        push!(body.args, :(using Test))
        push!(test_end_body.args, :(using Test))
        if !isempty(ctx.projectname)
            # this obviously assumes we're in an environment where projectname is reachable
            push!(body.args, :(using $(Symbol(ctx.projectname))))
            push!(test_end_body.args, :(using $(Symbol(ctx.projectname))))
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

        # add our `@testitem` quoted code to module body expr
        append!(body.args, ti.code.args)
        mod_expr = :(module $(gensym(name)) end)
        softscope_all!(body)
        mod_expr.args[3] = body

        # add the `test_end_expr` to a module to be run after the test item
        append!(test_end_body.args, test_end_expr.args)
        softscope_all!(test_end_body)
        test_end_mod_expr = :(module $(gensym(name * " test_end")) end)
        test_end_mod_expr.args[3] = test_end_body

        # eval the testitem into a temporary module, so that all results can be GC'd
        # once the test is done and sent over the wire. (However, note that anonymous modules
        # aren't always GC'd right now: https://github.com/JuliaLang/julia/issues/48711)
        # disabled for now since there were issues when tests tried serialize/deserialize
        # with things defined in an anonymous module
        # environment = Module()
        @debugv 1 "Evaluating test item $(repr(name))$(_on_worker())."
        _, stats = @timed_with_compilation _redirect_logs(logs == :eager ? DEFAULT_STDOUT[] : logpath(ti)) do
            with_source_path(() -> Core.eval(Main, mod_expr), ti.file)
            with_source_path(() -> Core.eval(Main, test_end_mod_expr), ti.file)
            nothing # return nothing as the first return value of @timed_with_compilation
        end
        @debugv 1 "Done evaluating test item $(repr(name))$(_on_worker())."
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
    @debugv 2 "Converting results for test item $(repr(name))$(_on_worker())."
    res = convert_results_to_be_transferrable(ts)
    log_testitem_done(ti, ctx.ntestitems)
    return TestItemResult(res, stats)
end

function convert_results_to_be_transferrable(ts::Test.AbstractTestSet)
    for (i, res) in enumerate(ts.results)
        ts.results[i] = convert_results_to_be_transferrable(res)
    end
    return ts
end

function convert_results_to_be_transferrable(res::Test.Pass)
    if res.test_type === :test_throws
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
