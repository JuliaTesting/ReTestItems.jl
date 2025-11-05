module ReTestItems

using Base: @lock, @kwdef
using Dates: DateTime, ISODateTimeFormat, format, now, unix2datetime
using Test: Test, DefaultTestSet, TestSetException
using .Threads: @spawn, nthreads
using Pkg: Pkg
using TestEnv
using Logging: current_logger, with_logger

export runtests, runtestitem
export @testsetup, @testitem
export TestSetup, TestItem, TestItemResult

const RETESTITEMS_TEMP_FOLDER = Ref{String}()
const DEFAULT_TESTITEM_TIMEOUT = 30*60
const DEFAULT_RETRIES = 0
const DEFAULT_MEMORY_THRESHOLD = Ref{Float64}(0.99)

if isdefined(Base, :errormonitor)
    const errmon = Base.errormonitor
else
    const errmon = identity
end

# Used by failures_first to sort failures before unseen before passes.
@enum _TEST_STATUS::UInt8 begin
    _FAILED = 0
    _UNSEEN = 1
    _PASSED = 2
end
const GLOBAL_TEST_STATUS = Dict{String,_TEST_STATUS}()
reset_test_status!() = (empty!(GLOBAL_TEST_STATUS); nothing)
_status_when_last_seen(ti) = get(GLOBAL_TEST_STATUS, ti.id, _UNSEEN)
function _cache_status!(ti)
    status = ti.is_non_pass[] ? _FAILED : _PASSED
    GLOBAL_TEST_STATUS[ti.id] = status
end

# We use the Test.jl stdlib `failfast` mechanism to implement `testitem_failfast`, but that
# feature was only added in Julia v1.9, so we define these shims so our code can be
# compatible with earlier Julia versions, with `testitem_failfast` just having no effect.
if isdefined(Test, :FailFastError)
    if isdefined(Test, :is_failfast_error)
        # https://github.com/JuliaLang/julia/pull/58695
        is_failfast_error = Test.is_failfast_error
    else
        is_failfast_error(err::Test.FailFastError) = true
        is_failfast_error(err::LoadError) = is_failfast_error(err.error)
        is_failfast_error(err) = false
    end
    CompatDefaultTestSet(a...; kw...) = DefaultTestSet(a...; kw...)
else # @testset does not yet support `failfast`
    is_failfast_error(err) = false
    # ignore `failfast` argument to DefaultTestSet
    CompatDefaultTestSet(a...; failfast::Bool=false, kw...) = DefaultTestSet(a...; kw...)
end

struct NoTestException <: Exception
    msg::String
end
# Three argument `showerror` with the `backtrace` keyword to swallow the backtrace,
# like for `Test.TestSetException`.
function Base.showerror(io::IO, exc::NoTestException, bt; backtrace=true)
    printstyled(io, exc.msg; color=Base.error_color())
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

include("debug.jl")
include("workers.jl")
using .Workers
include("macros.jl")
include("junit_xml.jl")
include("testcontext.jl")
include("log_capture.jl")
include("filtering.jl")

function __init__()
    if ccall(:jl_generating_output, Cint, ()) == 0 # not precompiling
        DEFAULT_STDOUT[] = stdout
        DEFAULT_STDERR[] = stderr
        DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
        DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
        # Disable killing workers based on memory pressure on MacOS til calculations fixed.
        # TODO: fix https://github.com/JuliaTesting/ReTestItems.jl/issues/113
        @static if Sys.isapple()
            DEFAULT_MEMORY_THRESHOLD[] = 1.0
        end
        # Defer setting up the temp folder for pkgimage relocability
        RETESTITEMS_TEMP_FOLDER[] = mkpath(joinpath(tempdir(), "ReTestItemsTempLogsDirectory"))
    end
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

function _validated_paths(paths, should_throw::Bool)
    return filter(paths) do p
        if !ispath(p)
            msg = "No such path $(repr(p))"
            should_throw ? throw(NoTestException(msg)) : @warn msg
            return false
        elseif !(is_test_file(p) || is_testsetup_file(p)) && isfile(p)
            msg = "$(repr(p)) is not a test file"
            should_throw ? throw(NoTestException(msg)) : @warn msg
            return false
        else
            return true
        end
    end
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
  If a `@testitem` sets its own `timeout` keyword, then that takes precedence.
  Fractional values are rounded up to the nearest second.
  Note timeouts are currently only applied when `nworkers > 0`.
- `retries::Int=$DEFAULT_RETRIES`: The number of times to retry a `@testitem` if either tests
  do not pass or, if running with multiple worker processes, the worker fails or hits the timeout limit
  while running the tests. Can also be set using the `RETESTITEMS_RETRIES` environment variable.
  If a `@testitem` sets its own `retries` keyword, then the maximum of these two retry numbers
  will be used as the retry limit for that `@testitem`. When `report=true`, the report will
  contain information for all runs of a `@testitem` that was retried.
- `nworkers::Int`: The number of worker processes to use for running `@testitem`s. Default 0. Can also be set
  using the `RETESTITEMS_NWORKERS` environment variable.
- `nworker_threads::Union{String,Int}`: The number of threads to use for each worker process. Defaults to 2.
  Can also be set using the `RETESTITEMS_NWORKER_THREADS` environment variable. Interactive threads are
  supported through a string (e.g. "auto,2").
- `worker_init_expr::Expr`: an expression that will be run on each worker process before any tests are run.
  Can be used to load packages or set up the environment. Must be a `:block` expression.
- `test_end_expr::Expr`: an expression that will be run after each testitem is run.
  Can be used to verify that global state is unchanged after running a test. Must be a `:block` expression.
  The `test_end_expr` is evaluated whether a testitem passes, fails, or errors. If the
  `testsetup` fails, then the `test_end_expr` is not run.
- `gc_between_testitems::Bool`: If `true`, a full garbage collection (GC) will be run after each test item is run.
  Defaults to `nworkers > 1`, i.e. `true` when running with multiple worker processes, since multiple worker processes
  cannot coordinate to trigger Julia's GC, and it should not be necessary to invoke the GC directly if running without
  workers or with a single worker (since the GC will be triggered automatically by the single process running all the tests).
  Can also be set using the `RETESTITEMS_GC_BETWEEN_TESTITEMS` environment variable.
  Tip: For complete control over GC, set `gc_between_testitems=false` and manually trigger GC in `test_end_expr`.
- `memory_threshold::Real`: Sets the fraction of memory that can be in use before a worker processes are
  restarted to free memory. Defaults to $(DEFAULT_MEMORY_THRESHOLD[]). Only supported with `nworkers > 0`.
  For example, if set to 0.8, then when >80% of the available memory is in use, a worker process will be killed and
  replaced with a new worker before the next testitem is run. The testitem will then be run on the new worker
  process, regardless of if memory pressure dropped below the threshold. If the memory pressure remains above the
  threshold, then a worker process will again be replaced before the next testitem is run.
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
- `validate_paths::Bool=false`: If `true`, `runtests` will throw an error if any of the
  `paths` passed to it cannot contain test files, either because the path doesn't exist or
  the path points to a file which is not a test file. Default is `false`.
  Can also be set using the `RETESTITEMS_VALIDATE_PATHS` environment variable.
- `timeout_profile_wait::Real=0`: When non-zero, a worker that times-out will trigger a CPU profile
   for which we will wait `timeout_profile_wait` seconds before terminating the worker.
   Zero means no profile will be taken. Can also be set using the `RETESTITEMS_TIMEOUT_PROFILE_WAIT`
   environment variable. See the [Profile documentation](https://docs.julialang.org/en/v1/stdlib/Profile/#Triggered-During-Execution)
   for more information on triggered profiles. Note you can use `worker_init_expr` to tweak the profile settings on workers.
- `failfast::Bool=false`: If true, no additional testitems are run after a testitem fails.
  A testitem is considered to have failed if it does not pass after retries.
  Note that in the current implementation testitems already running on other workers in parallel with the failing testitem are allowed to complete,
  but this may be improved in a future version.
  Can also be set using the `RETESTITEMS_FAILFAST` environment variable.
- `testitem_failfast::Bool=failfast`: If true, a testitem stops as soon as there is a test failure or error.
  Can also be set using the `RETESTITEMS_TESTITEM_FAILFAST` environment variable.
  Defaults to the value passed to the `failfast` keyword.
  If a `@testitem` sets its own `failfast` keyword, then that takes precedence.
  Note that the `testitem_failfast` keyword only takes effect in Julia v1.9+ and is ignored in earlier Julia versions.
- `failures_first::Bool=true`: if `true`, first runs test items that failed the last time
  they ran, followed by new test items, followed by test items that passed the last time they ran.
  Can also be set using the `RETESTITEMS_FAILURES_FIRST` environment variable.
"""
function runtests end

runtests(; kw...) = runtests(Returns(true), dirname(Base.active_project()); kw...)
runtests(shouldrun; kw...) = runtests(shouldrun, dirname(Base.active_project()); kw...)
runtests(paths::AbstractString...; kw...) = runtests(Returns(true), paths...; kw...)

runtests(pkg::Module; kw...) = runtests(Returns(true), pkg; kw...)
function runtests(shouldrun, pkg::Module; kw...)
    dir = pkgdir(pkg)
    isnothing(dir) && error("Could not find directory for `$pkg`")
    return runtests(shouldrun, dir; kw...)
end

@kwdef struct _Config
    nworkers::Int
    nworker_threads::String
    worker_init_expr::Expr
    test_end_expr::Expr
    testitem_timeout::Int
    testitem_failfast::Bool
    failfast::Bool
    retries::Int
    logs::Symbol
    report::Bool
    verbose_results::Bool
    timeout_profile_wait::Int
    memory_threshold::Float64
    gc_between_testitems::Bool
    failures_first::Bool
end


function runtests(
    shouldrun,
    paths::AbstractString...;
    nworkers::Int=parse(Int, get(ENV, "RETESTITEMS_NWORKERS", "0")),
    nworker_threads::Union{Int,String}=get(ENV, "RETESTITEMS_NWORKER_THREADS", "2"),
    worker_init_expr::Expr=Expr(:block),
    testitem_timeout::Real=parse(Float64, get(ENV, "RETESTITEMS_TESTITEM_TIMEOUT", string(DEFAULT_TESTITEM_TIMEOUT))),
    retries::Int=parse(Int, get(ENV, "RETESTITEMS_RETRIES", string(DEFAULT_RETRIES))),
    memory_threshold::Real=parse(Float64, get(ENV, "RETESTITEMS_MEMORY_THRESHOLD", string(DEFAULT_MEMORY_THRESHOLD[]))),
    debug=0,
    name::Union{Regex,AbstractString,Nothing}=nothing,
    tags::Union{Symbol,AbstractVector{Symbol},Nothing}=nothing,
    report::Bool=parse(Bool, get(ENV, "RETESTITEMS_REPORT", "false")),
    logs::Symbol=Symbol(get(ENV, "RETESTITEMS_LOGS", default_log_display_mode(report, nworkers))),
    verbose_results::Bool=(logs !== :issues && isinteractive()),
    test_end_expr::Expr=Expr(:block),
    validate_paths::Bool=parse(Bool, get(ENV, "RETESTITEMS_VALIDATE_PATHS", "false")),
    timeout_profile_wait::Real=parse(Int, get(ENV, "RETESTITEMS_TIMEOUT_PROFILE_WAIT", "0")),
    gc_between_testitems::Bool=parse(Bool, get(ENV, "RETESTITEMS_GC_BETWEEN_TESTITEMS", string(nworkers > 1))),
    failfast::Bool=parse(Bool, get(ENV, "RETESTITEMS_FAILFAST", "false")),
    testitem_failfast::Bool=parse(Bool, get(ENV, "RETESTITEMS_TESTITEM_FAILFAST", string(failfast))),
    failures_first::Bool=parse(Bool, get(ENV, "RETESTITEMS_FAILURES_FIRST", "true")),
)
    nworker_threads = _validated_nworker_threads(nworker_threads)
    paths′ = _validated_paths(paths, validate_paths)

    logs in LOG_DISPLAY_MODES || throw(ArgumentError("`logs` must be one of $LOG_DISPLAY_MODES, got $(repr(logs))"))
    report && logs == :eager && throw(ArgumentError("`report=true` is not compatible with `logs=:eager`"))
    (0 ≤ memory_threshold ≤ 1) || throw(ArgumentError("`memory_threshold` must be between 0 and 1, got $(repr(memory_threshold))"))
    testitem_timeout > 0 || throw(ArgumentError("`testitem_timeout` must be a positive number, got $(repr(testitem_timeout))"))
    timeout_profile_wait >= 0 || throw(ArgumentError("`timeout_profile_wait` must be a non-negative number, got $(repr(timeout_profile_wait))"))
    test_end_expr.head === :block || throw(ArgumentError("`test_end_expr` must be a `:block` expression, got a `$(repr(test_end_expr.head))` expression"))
    # If we were given paths but none were valid, then nothing to run.
    !isempty(paths) && isempty(paths′) && return nothing
    ti_filter = TestItemFilter(shouldrun, tags, name)
    nworkers = max(0, nworkers)
    retries = max(0, retries)
    testitem_timeout = ceil(Int, testitem_timeout)
    timeout_profile_wait = ceil(Int, timeout_profile_wait)
    (timeout_profile_wait > 0 && Sys.iswindows()) && @warn "CPU profiles on timeout is not supported on Windows, ignoring `timeout_profile_wait`"
    mkpath(RETESTITEMS_TEMP_FOLDER[]) # ensure our folder wasn't removed
    save_current_stdio()
    cfg = _Config(; nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, testitem_failfast, failfast, retries, logs, report, verbose_results, timeout_profile_wait, memory_threshold, gc_between_testitems, failures_first)
    debuglvl = Int(debug)
    if debuglvl > 0
        withdebug(debuglvl) do
            _runtests(ti_filter, paths′, cfg)
        end
    else
        return _runtests(ti_filter, paths′, cfg)
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

function _runtests(ti_filter, paths, cfg::_Config)
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
            return _runtests_in_current_env(ti_filter, paths, proj_file, cfg)
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
                _runtests_in_current_env(ti_filter, paths, proj_file, cfg)
            finally
                Base.set_active_project(orig_proj)
            end
        end
    end
end

function _runtests_in_current_env(
    ti_filter, paths, projectfile::String, cfg::_Config
)
    start_time = time()
    proj_name = something(Pkg.Types.read_project(projectfile).name, "")
    @info "Scanning for test items in project `$proj_name` at paths: $(join(paths, ", "))"
    inc_time = time()
    @debugv 1 "Including tests in $paths"
    testitems, _ = include_testfiles!(proj_name, projectfile, paths, ti_filter, cfg.verbose_results, cfg.report)
    @debugv 1 "Done including tests in $paths"
    nworkers = cfg.nworkers
    nworker_threads = cfg.nworker_threads
    ntestitems = length(testitems.testitems)
    @info "Finished scanning for test items in $(round(time() - inc_time, digits=2)) seconds."
    if ntestitems == 0
        throw(NoTestException("No test items found."))
    end
    @info "Scheduling $ntestitems tests on pid $(Libc.getpid())" *
        (nworkers == 0 ? "" : " with $nworkers worker processes and $nworker_threads threads per worker.")
    try
        if cfg.failures_first && !isempty(GLOBAL_TEST_STATUS)
            sort!(testitems.testitems; by=_status_when_last_seen)
            foreach(enumerate(testitems.testitems)) do (i, ti)
                ti.number[] = i # reset number to match new order
            end
            is_sorted_queue = true
        else
            is_sorted_queue = false
        end
        if nworkers == 0
            length(cfg.worker_init_expr.args) > 0 && error("worker_init_expr is set, but will not run because number of workers is 0.")
            # This is where we disable printing for the serial executor case.
            Test.TESTSET_PRINT_ENABLE[] = false
            ctx = TestContext(proj_name, ntestitems)
            # we use a single TestSetupModules
            ctx.setups_evaled = TestSetupModules()
            for (i, testitem) in enumerate(testitems.testitems)
                testitem.workerid[] = Libc.getpid()
                testitem.eval_number[] = i
                @atomic :monotonic testitems.count += 1
                run_number = 1
                max_runs = 1 + max(cfg.retries, testitem.retries)
                is_non_pass = false
                while run_number ≤ max_runs
                    res = runtestitem(testitem, ctx; cfg.test_end_expr, cfg.verbose_results, cfg.logs, failfast=cfg.testitem_failfast)
                    ts = res.testset
                    print_errors_and_captured_logs(testitem, run_number; cfg.logs)
                    report_empty_testsets(testitem, ts)
                    if cfg.gc_between_testitems
                        @debugv 2 "Running GC"
                        GC.gc(true)
                    end
                    testitem.is_non_pass[] = is_non_pass = any_non_pass(ts)
                    if is_non_pass && run_number != max_runs
                        run_number += 1
                        @info "Retrying $(repr(testitem.name)). Run=$run_number."
                    else
                        break
                    end
                end
                if cfg.failfast && is_non_pass
                    cancel!(testitems)
                    print_failfast_cancellation(testitem)
                    break
                end
            end
        elseif !isempty(testitems.testitems)
            # Try to free up memory on the coordinator before starting workers, since
            # the workers won't be able to collect it if they get under memory pressure.
            GC.gc(true)
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
                        $workers[$i] = robust_start_worker($proj_name, $(cfg.nworker_threads), $(cfg.worker_init_expr), $ntestitems; worker_num=$i)
                    end
                end
            end
            # Now all workers are started, we can begin processing test items.
            @info "Starting running test items"
            starting = get_starting_testitems(testitems, nworkers; is_sorted=is_sorted_queue)
            @sync for (i, w) in enumerate(workers)
                ti = starting[i]
                @spawn begin
                    with_logger(original_logger) do
                        manage_worker($w, $proj_name, $testitems, $ti, $cfg; worker_num=$i)
                    end
                end
            end
        end
        Test.TESTSET_PRINT_ENABLE[] = true # reenable printing so our `finish` prints
        # Let users know if tests are done, and if all of them ran (or if we failed fast).
        # Print this above the final report as there might have been other logs printed
        # since a failfast-cancellation was printed, but print it ASAP after tests finish
        # in case any of the recording/reporting steps have an issue.
        print_completion_summary(testitems; failedfast=(cfg.failfast && is_cancelled(testitems)))
        record_results!(testitems)
        cfg.report && write_junit_file(proj_name, dirname(projectfile), testitems.graph.junit)
        @debugv 1 "Calling Test.finish(testitems)"
        Test.finish(testitems) # print summary of total passes/failures/errors
    finally
        Test.TESTSET_PRINT_ENABLE[] = true
        @debugv 1 "Cleaning up test setup logs"
        foreach(Iterators.filter(endswith(".log"), readdir(RETESTITEMS_TEMP_FOLDER[], join=true))) do logfile
            try
                # See https://github.com/JuliaTesting/ReTestItems.jl/issues/124
                rm(logfile; force=true)  # `force` to ignore error if file already cleaned up
            catch err
                @debug "Error while attempting to remove $(logfile)" err
            end
        end
        @debugv 1 "Done cleaning up test setup logs"
    end
    @debugv 1 "DONE"
    return nothing
end

# Start a new `Worker` with `nworker_threads` threads and run `worker_init_expr` on it.
# The provided `worker_num` is only for logging purposes, and not persisted as part of the worker.
function start_worker(proj_name, nworker_threads::String, worker_init_expr::Expr, ntestitems::Int; worker_num=nothing)
    w = Worker(; threads=nworker_threads)
    i = worker_num == nothing ? "" : " $worker_num"
    proj = Base.active_project()
    # remote_fetch here because we want to make sure the worker is all setup before starting to eval testitems
    remote_fetch(w, quote
        Base.set_active_project($proj)
        using ReTestItems, Test
        Test.TESTSET_PRINT_ENABLE[] = false
        const GLOBAL_TEST_CONTEXT = ReTestItems.TestContext($proj_name, $ntestitems)
        GLOBAL_TEST_CONTEXT.setups_evaled = ReTestItems.TestSetupModules()
        nthreads_str = $nworker_threads
        @info "Starting test worker$($i) on pid = $(Libc.getpid()), with $nthreads_str threads"
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

# Can't just check `ts.anynonpass` because that only gets set when `finish` is called, which
# won't have happened if the testset wasn't the "root" testset -- e.g. `runtests` is being
# called with nworkers=0 from within a testset -- instead we have to check all the results.
function any_non_pass(ts::DefaultTestSet)
    for res in ts.results
        if res isa Union{Test.Fail, Test.Error}
            return true
        elseif res isa DefaultTestSet
            if any_non_pass(res::DefaultTestSet)
                return true
            end
        end
    end
    return false
end


function record_timeout!(testitem, run_number::Int, timeout_s::Int)
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
    msg = "Timed out after $time_str running test item $(repr(testitem.name)) (run=$run_number)"
    record_test_error!(testitem, msg, timeout_s)
end

function record_worker_terminated!(testitem, worker::Worker, run_number::Int)
    termsignal = worker.process.termsignal
    msg = "Worker process aborted (signal=$termsignal) running test item $(repr(testitem.name)) (run=$run_number)"
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

# The provided `worker_num` is only for logging purposes, and not persisted as part of the worker.
function manage_worker(
    worker::Worker, proj_name::AbstractString, testitems::TestItems, testitem::Union{TestItem,Nothing}, cfg::_Config;
    worker_num::Int
)
    ntestitems = length(testitems.testitems)
    run_number = 1
    memory_threshold_percent = 100 * cfg.memory_threshold
    while testitem !== nothing
        ch = Channel{TestItemResult}(1)
        if memory_percent() > memory_threshold_percent
            @warn "Memory usage ($(Base.Ryu.writefixed(memory_percent(), 1))%) is higher than threshold ($(Base.Ryu.writefixed(memory_threshold_percent, 1))%). Restarting process for worker $worker_num to try to free memory."
            terminate!(worker)
            wait(worker)
            worker = robust_start_worker(proj_name, cfg.nworker_threads, cfg.worker_init_expr, ntestitems)
        end
        testitem.workerid[] = worker.pid
        timeout = something(testitem.timeout, cfg.testitem_timeout)
        fut = remote_eval(worker, :(ReTestItems.runtestitem($testitem, GLOBAL_TEST_CONTEXT; test_end_expr=$(QuoteNode(cfg.test_end_expr)), verbose_results=$(cfg.verbose_results), logs=$(QuoteNode(cfg.logs)), failfast=$(cfg.testitem_failfast))))
        max_runs = 1 + max(cfg.retries, testitem.retries)
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
                print_errors_and_captured_logs(testitem, run_number; cfg.logs)
                report_empty_testsets(testitem, ts)
                if cfg.gc_between_testitems
                    @debugv 2 "Running GC on $worker"
                    remote_fetch(worker, :(GC.gc(true)))
                end
                testitem.is_non_pass[] = is_non_pass = any_non_pass(ts)
                if is_non_pass && run_number != max_runs
                    run_number += 1
                    @info "Retrying $(repr(testitem.name)) on $worker. Run=$run_number."
                else
                    if cfg.failfast && is_non_pass
                        already_cancelled = cancel!(testitems)
                        already_cancelled || print_failfast_cancellation(testitem)
                    end
                    testitem = next_testitem(testitems, testitem.number[])
                    run_number = 1
                end
            finally
                close(timer)
            end
        catch e
            @debugv 2 "Error: $e"
            # Handle the exception
            if e isa TimeoutException
                if cfg.timeout_profile_wait > 0
                    @warn "$worker timed out running test item $(repr(testitem.name)) after $timeout seconds. \
                        A CPU profile will be triggered on the worker and then it will be terminated."
                    trigger_profile(worker, cfg.timeout_profile_wait, :timeout)
                end
                terminate!(worker, :timeout)
                wait(worker)
                # TODO: We print the captured logs after the worker is terminated,
                # which means that we include an annoying stackrace from the worker termination,
                # but the profiles don't seem to get flushed properly if we don't do this.
                # This is not an issue with eager logs, but when going through a file, this seems to help.
                println(DEFAULT_STDOUT[])
                _print_captured_logs(DEFAULT_STDOUT[], testitem, run_number)
                @error "$worker timed out running test item $(repr(testitem.name)) after $timeout seconds. \
                    Recording test error."
                record_timeout!(testitem, run_number, timeout)
            elseif e isa WorkerTerminatedException
                println(DEFAULT_STDOUT[])
                _print_captured_logs(DEFAULT_STDOUT[], testitem, run_number)
                @error "$worker died running test item $(repr(testitem.name)). \
                    Recording test error."
                record_worker_terminated!(testitem, worker, run_number)
            else
                # We don't expect any other kind of error, so rethrow, which will propagate
                # back up to the main coordinator task and throw to the user
                println(DEFAULT_STDOUT[])
                _print_captured_logs(DEFAULT_STDOUT[], testitem, run_number)
                rethrow()
            end
            # Handle retries
            if run_number == max_runs
                if cfg.failfast
                    already_cancelled = cancel!(testitems)
                    already_cancelled || print_failfast_cancellation(testitem)
                end
                testitem = next_testitem(testitems, testitem.number[])
                run_number = 1
            else
                run_number += 1
                @info "Retrying $(repr(testitem.name)) on a new worker $worker_num process. Run=$run_number."
            end
            # The worker was terminated, so replace it unless there are no more testitems to run
            if testitem !== nothing
                worker = robust_start_worker(proj_name, cfg.nworker_threads, cfg.worker_init_expr, ntestitems)
            end
            # Now loop back around to reschedule the testitem
            continue
        end
    end
    @info "All tests on worker $worker_num completed. Closing $worker."
    close(worker)
    @debugv 1 "Worker $worker_num closed: $(worker)"
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

# Like `relpath` but assumes `path` is nested under `startdir`, else just returns `path`.
# Always returns a `SubString` to be type-stable.
function nestedrelpath(path::T, startdir::AbstractString) where {T <: AbstractString}
    path == startdir && return SubString{T}(".")
    relp = chopprefix(path, startdir)
    relp == path && return relp
    sep = Base.Filesystem.path_separator
    if endswith(startdir, sep)
        return relp
    elseif startswith(relp, sep)
        return chopprefix(relp, sep)
    else # `startdir` was a prefix of `path` but not a directory
        return SubString{T}(path)
    end
end

# is `dir` the root of a subproject inside the current project?
function _is_subproject(dir, current_projectfile)
    projectfile = _project_file(dir)
    isnothing(projectfile) && return false

    projectfile = abspath(projectfile)
    projectfile == current_projectfile && return false
    # a `test/Project.toml` is special and doesn't indicate a subproject
    current_project_dir = dirname(current_projectfile)
    rel_projectfile = nestedrelpath(projectfile, current_project_dir)
    rel_projectfile == joinpath("test", "Project.toml") && return false
    return true
end

# for each directory, kick off a recursive test-finding task
# Returns (testitems::TestItems, setups::Dict{Symbol,TestSetup})
# Assumes `isdir(project_root)`, which is guaranteed by `_runtests`.
function include_testfiles!(project_name, projectfile, paths, ti_filter::TestItemFilter, verbose_results::Bool, report::Bool)
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
        rpath = nestedrelpath(root, project_root)
        startswith(rpath, hidden_re) && continue # skip hidden directories
        dir_node = DirNode(rpath; report, verbose=verbose_results)
        dir_nodes[rpath] = dir_node
        push!(get(dir_nodes, dirname(rpath), root_node), dir_node)
        for file in files
            startswith(file, hidden_re) && continue # skip hidden files
            filepath = joinpath(root, file)
            # We filter here, rather than the testitem level, to make sure we don't
            # `include` a file that isn't supposed to be a test-file at all, e.g. its
            # not on a path the user requested but it happens to have a test-file suffix.
            # We always include testsetup-files so users don't need to request them,
            # even if they're not in a requested path, e.g. they are a level up in the
            # directory tree. The testsetup-file suffix is hopefully specific enough
            # to ReTestItems that this doesn't lead to `include`ing unexpected files.
            if !(is_testsetup_file(filepath) || (is_test_file(filepath) && is_requested(filepath, paths)))
                continue
            end
            fpath = nestedrelpath(filepath, project_root)
            file_node = FileNode(fpath, ti_filter; report, verbose=verbose_results)
            testitem_names = Set{String}() # to enforce that names in the same file are unique
            push!(dir_node, file_node)
            @debugv 1 "Including test items from file `$filepath`"
            @spawn begin
                task_local_storage(:__RE_TEST_RUNNING__, true) do
                    task_local_storage(:__RE_TEST_ITEMS__, ($file_node, $testitem_names)) do
                        task_local_storage(:__RE_TEST_PROJECT__, $(project_root)) do
                            task_local_storage(:__RE_TEST_SETUPS__, $setup_channel) do
                                Base.include($ti_filter, Main, $filepath)
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
        source = string(nestedrelpath(ti.file, ti.project_root), ":", ti.line)
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

# Check the `skip` keyword, and return a `Bool` indicating if we should skip the testitem.
# If `skip` is an expression, run it in a new module just like how we run testitems.
# If the `skip` expression doesn't return a Bool, throw an informative error.
function should_skip(ti::TestItem)
    ti.skip isa Bool && return ti.skip
    # `skip` is an expression.
    # Give same scope as testitem body, e.g. imports should work.
    skip_body = deepcopy(ti.skip::Expr)
    softscope_all!(skip_body)
    # Run in a new module to not pollute `Main`.
    mod = Module(Symbol(:skip_, ti.name))
    skip = Core.eval(mod, skip_body)
    !isa(skip, Bool) && _throw_not_bool(ti, skip)
    return skip::Bool
end
_throw_not_bool(ti, skip) = error("Test item $(repr(ti.name)) `skip` keyword must be a `Bool`, got `skip=$(repr(skip))`")

# Log that we skipped the testitem, and record a "skipped" test result with empty stats.
function skiptestitem(ti::TestItem, ctx::TestContext; verbose_results::Bool=true)
    ts = DefaultTestSet(ti.name; verbose=verbose_results)
    Test.record(ts, Test.Broken(:skipped, ti.name))
    push!(ti.testsets, ts)
    stats = PerfStats()
    push!(ti.stats, stats)
    log_testitem_skipped(ti, ctx.ntestitems)
    return TestItemResult(ts, stats)
end


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
# The `failfast` keyword implements the `testitem_failfast` mechanism. We name it "failfast"
# here rather than "testitem_failfast" (the name we use for it in `runtests`), so as to give
# `runtestitem` a nicer API... regrettably `runtestitem` is exported so best it has an okay API.
function runtestitem(
    ti::TestItem, ctx::TestContext;
    test_end_expr::Union{Nothing,Expr}=nothing, logs::Symbol=:eager, verbose_results::Bool=true, finish_test::Bool=true, catch_test_error::Bool=true,
    failfast::Bool=false,
)
    if should_skip(ti)::Bool
        return skiptestitem(ti, ctx; verbose_results)
    end
    if test_end_expr === nothing
        has_test_end_expr = false
        test_end_expr = Expr(:block)
    else
        has_test_end_expr = true
    end
    name = ti.name
    failedfast = false
    log_testitem_start(ti, ctx.ntestitems)
    ts = CompatDefaultTestSet(name; verbose=verbose_results, failfast=something(ti.failfast, failfast))
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
        @debugv 1 "Running test item $(repr(name))$(_on_worker())."
        _, stats = @timed_with_compilation _redirect_logs(logs == :eager ? DEFAULT_STDOUT[] : logpath(ti)) do
            # Always run the test_end_mod_expr, even if the test item fails / throws
            try
                with_source_path(() -> Core.eval(Main, mod_expr), ti.file)
            finally
                has_test_end_expr && @debugv 1 "Running test_end_expr for test item $(repr(name))$(_on_worker())."
                with_source_path(() -> Core.eval(Main, test_end_mod_expr), ti.file)
            end
            nothing # return nothing as the first return value of @timed_with_compilation
        end
        @debugv 1 "Done running test item $(repr(name))$(_on_worker())."
    catch err
        err isa InterruptException && rethrow()
        # Handle exceptions thrown outside a `@test` in the body of the @testitem:
        # Copied from Test.@testset's catch block:
        # If an inner testset had `failfast=true` and there was a failure/error, then the root
        # testset will throw a `Test.FailFastError` to force the root testset to stop running.
        # We don't need to record that `Test.FailFastError`, since its not itself a test
        # error, it is just the mechanism used to interrupt tests.
        if is_failfast_error(err)
            failedfast = true
        else
            try
                Test.record(ts, Test.Error(:nontest_error, Test.Expr(:tuple), err,
                    (Test.Base).current_exceptions(),
                    LineNumberNode(ti.line, ti.file)))
            catch err2
                # If the root testset had `failfast=true` and itself threw an error outside
                # of a test, then `record` will throw a `Test.FailFastError`.
                is_failfast_error(err2) || rethrow()
                failedfast = true
            end
        end
    finally
        # Make sure all test setup logs are commited to file
        foreach(ts->isassigned(ts.logstore) && flush(ts.logstore[]), ti.testsetups)
        ts1 = Test.pop_testset()
        task_local_storage()[:__TESTITEM_ACTIVE__] = prev
        @assert ts1 === ts
        if finish_test
            if catch_test_error
                try
                    Test.finish(ts) # This will throw an exception if any of the tests failed.
                catch e
                    e isa TestSetException || rethrow()
                end
            else
                Test.finish(ts)
            end
        end
    end
    @debugv 1 "Test item $(repr(name)) done$(_on_worker())."
    push!(ti.testsets, ts)
    push!(ti.stats, stats)
    @debugv 2 "Converting results for test item $(repr(name))$(_on_worker())."
    res = convert_results_to_be_transferrable(ts)
    log_testitem_done(ti, ctx.ntestitems; failedfast)
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
