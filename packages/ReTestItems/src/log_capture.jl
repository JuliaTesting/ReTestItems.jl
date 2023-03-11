const DEFAULT_STDOUT = Ref{IO}()
const DEFAULT_STDERR = Ref{IO}()
const DEFAULT_LOGSTATE = Ref{Base.CoreLogging.LogState}()
const DEFAULT_LOGGER = Ref{Base.CoreLogging.AbstractLogger}()

function save_current_stdio()
    DEFAULT_STDERR[] = stderr
    DEFAULT_STDOUT[] = stdout
    DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
    DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
end

function logfile_name(ti::TestItem)
    # Replacing reserved chars https://en.wikipedia.org/wiki/Filename
    # File name should remain unique due to the inclusion of `ti.id`.
    safe_name = replace(ti.name, r"[/\\\?%\*\:\|\"\<\>\.\,\;\=\s\$\#\@]" => "_")
    return string("ReTestItems_test_", first(safe_name, 150), "_", ti.id, ".log")
end
function logfile_name(ts::TestSetup)
    # Test setup names should be unique to begin with, but we add hash of their location to be sure
    string("ReTestItems_setup_", ts.name, "_", hash(ts.file, UInt(ts.line)), ".log")
end
logpath(ti) = joinpath(RETESTITEMS_TEMP_FOLDER, logfile_name(ti))

"""
    _capture_logs(f, ti::Union{TestItem,TestSetup})

Redirects stdout and stderr to a temporary file corresponding to `ti`.
For multithreaded test executors, this requires `_setup_multithreaded_log_capture()` to be called beforehand.

The Multithreaded case won't properly capture logs if the evaluated test code modifies global
logstate -- this would make the context variable unreachable to that part of the code.
A workaround would be to use `ContextVariablesX.with_logger` or to switch to a distributed executor.
"""
_capture_logs(f, ti::TestItem) = open(io->_capture_logs(f, io), logpath(ti), "w")
_capture_logs(f, ts::TestSetup) = _capture_logs(f, ts.logstore[])
function _capture_logs(f, io::IO)
    colored_io = IOContext(io, :color => get(DEFAULT_STDOUT[], :color, false))
    if !(nthreads() > 1 && nprocs() == 1)
        # Distributed or single-process & single-threaded executor case
        redirect_stdio(f, stdout=colored_io, stderr=colored_io)
    else
        # Multithreaded executor case
        # invokelatest to makes sure we don't run into issues if different task changed the
        # global logger, in which case we might hit a world age issue
        Base.invokelatest(ContextVariablesX.with_context, f, var"#CURRENT_LOGSTORE" => colored_io)
    end
end

# A lock that helps to stagger prints to DEFAULT_STDOUT, e.g. when there are log messages
# comming from distributed workers, reports for stalled tests and outputs of
# `print_errors_and_captured_logs`.
const LogCaptureLock = ReentrantLock()
macro loglock(expr)
    return :(@lock LogCaptureLock $(esc(expr)))
end

# NOTE: stderr and stdout are not safe to use during precompilation time,
# specifically until `Base.init_stdio` has been called. This is why we store
# the e.g. DEFAULT_STDOUT reference during __init__.
_not_compiling() = ccall(:jl_generating_output, Cint, ()) == 0

### Logging and reporting helpers ##########################################################

_on_worker() = nprocs() == 1 ? "" : " on worker $(myid())"
_on_worker(ti::TestItem) = nprocs() == 1 ? "" : " on worker $(ti.workerid[])"
_file_info(ti::Union{TestSetup,TestItem}) = string(relpath(ti.file, ti.project_root), ":", ti.line)
_has_logs(ts::TestSetup) = filesize(logpath(ts)) > 0
# The path might not exist if a testsetup always throws an error and we don't get to actually
# evaluate the test item.
_has_logs(ti::TestItem) = (path = logpath(ti); (isfile(path) && filesize(path) > 0))


"""
    print_errors_and_captured_logs(ti::TestItem, ts::DefaultTestSet; verbose=false)

When a testitem doesn't succeed, we print the corresponding error/failure reports
from the testset and any logs that we captured while the testitem was eval()'d.

When `verbose` is `true`, any captured logs are printed regardless of test result status.

Nothing is printed when no logs were captures and no failures or errors occured.
"""
print_errors_and_captured_logs(ti::TestItem, ts::DefaultTestSet; verbose=false) =
    print_errors_and_captured_logs(DEFAULT_STDOUT[], ti, ts, verbose=verbose)
function print_errors_and_captured_logs(io, ti::TestItem, ts::DefaultTestSet; verbose=false)
    has_errors = ts.anynonpass
    has_logs = _has_logs(ti) || any(_has_logs, ti.testsetups)
    if has_errors || verbose
        report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
        _print_captured_logs(report_iob, ti)
        has_errors && _print_test_errors(report_iob, ts, _on_worker(ti))
        if has_errors || has_logs
            # a newline to visually separate the report for the current test item
            println(report_iob)
            # Printing in one go to minimize chance of mixing with other concurrent prints
            @loglock write(io, take!(report_iob.io))
        end
    end
    rm(logpath(ti), force=true) # cleanup
    return nothing
end

function _print_captured_logs(io, setup::TestSetup, ti::Union{Nothing,TestItem}=nothing)
    if _has_logs(setup)
        ti_info = isnothing(ti) ? "" : " (dependency of $(repr(ti.name)))"
        printstyled(io, "Captured logs"; bold=true, color=Base.info_color())
        print(io, " for test setup \"$(setup.name)\"$(ti_info) at ")
        printstyled(io, _file_info(setup); bold=true, color=:default)
        println(io, isnothing(ti) ? _on_worker() : _on_worker(ti))
        open(logpath(setup), "r") do logstore
            write(io, logstore)
        end
    end
    return nothing
end

function _print_captured_logs(io, ti::TestItem)
    for setup in ti.testsetups
        _print_captured_logs(io, setup, ti)
    end
    if _has_logs(ti)
        printstyled(io, "Captured logs"; bold=true, color=Base.info_color())
        print(io, " for test item $(repr(ti.name)) at ")
        printstyled(io, _file_info(ti); bold=true, color=:default)
        println(io, _on_worker(ti))
        open(logpath(ti), "r") do logstore
            write(io, logstore)
        end
    end
    return nothing
end

# Adapted from Test.print_test_errors to print into an IOBuffer and to report worker id if needed
function _print_test_errors(report_iob, ts::DefaultTestSet, worker_info)
    for result in ts.results
        if isa(result, Test.Error) || isa(result, Test.Fail)
            println(report_iob, "Error in testset $(repr(ts.description))$(worker_info):")
            show(report_iob, result)
            println(report_iob)
        elseif isa(result, DefaultTestSet)
            _print_test_errors(report_iob, result, worker_info)
        end
    end
    return nothing
end

# Called from a Timer object if a tests takes longer than STALLED_LIMIT_SECONDS
function log_stalled(ti::TestItem)
    report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
    print(report_iob, format(now(), "HH:MM:SS "))
    printstyled(report_iob, "STALLED"; bold=true)
    print(report_iob, " test item $(repr(ti.name)) at ")
    printstyled(report_iob, _file_info(ti); bold=true, color=:default)
    println(report_iob, _on_worker(ti))
    # Let's also print any logs we might have collected for the stalled test item
    _print_captured_logs(report_iob, ti)
    filesize(logpath(ti)) > 0 && println(report_iob)
    @loglock write(DEFAULT_STDOUT[], take!(report_iob.io))
end

# Marks the start of each test item
function log_running(ti::TestItem)
    report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
    print(report_iob, format(now(), "HH:MM:SS "))
    printstyled(report_iob, "RUNNING"; bold=true)
    print(report_iob, " test item $(repr(ti.name)) at ")
    printstyled(report_iob, _file_info(ti); bold=true, color=:default)
    println(report_iob, _on_worker(ti))
    @loglock write(DEFAULT_STDOUT[], take!(report_iob.io))
end

function report_empty_testsets(ti::TestItem, ts::DefaultTestSet)
    empty_testsets = String[]
    _find_empty_testsets!(empty_testsets, ts)
    if !isempty(empty_testsets)
        @warn """
            Test item $(repr(ti.name)) at $(_file_info(ti)) contains test sets without tests:
            $(join(empty_testsets, '\n'))
            """
    end
    return nothing
end

function _find_empty_testsets!(empty_testsets::Vector{String}, ts::DefaultTestSet)
    if (isempty(ts.results) && ts.n_passed == 0)
        push!(empty_testsets, repr(ts.description))
        return nothing
    end
    for result in ts.results
        isa(result, DefaultTestSet) && _find_empty_testsets!(empty_testsets, result)
    end
    return nothing
end

### Log capture for multithreaded executor #################################################

struct ReTestItemsCapturingIO <: IO end
const STANDARD_IO_CONSUMER = ReTestItemsCapturingIO()

function Base.isopen(::ReTestItemsCapturingIO)
    isnothing(get(var"#CURRENT_LOGSTORE")) ? isopen(DEFAULT_STDOUT[]) : true
end
Base.displaysize(::ReTestItemsCapturingIO) = displaysize(DEFAULT_STDOUT[])
# Our overload for the `redirect_{stdout,stderr}` methods
function (f::Base.RedirectStdStream)(p::ReTestItemsCapturingIO)
    Base._redirect_io_global(p, f.unix_fd)
    return p
end

# Overloads needed to capture printed colors
Base.get(::ReTestItemsCapturingIO, key::Symbol, default) = key === :color ? Base.get_have_color() : default
Base.unwrapcontext(io::ReTestItemsCapturingIO) = (io, Base.unwrapcontext(DEFAULT_STDOUT[])[2])

# When the #CURRENT_LOGSTORE is set, we redirect all writes that would normally go to stdout
# to an IOStream referenced by it. This way we achieve log capture while using multithreaded
# test executors. Sadly, context variables are not visible when logstate gets changed by the
# tested code in which case we recommend to use distributed executors or to use
# `ContextVariablesX.with_logger` instead.
ContextVariablesX.@contextvar var"#CURRENT_LOGSTORE"::IOContext{IOStream};
for T in (UInt8, Vector{UInt8}, String, Char, AbstractChar, AbstractString, IO)
    @eval function Base.write(io::Union{ReTestItemsCapturingIO,IOContext{ReTestItemsCapturingIO}}, x::$(T))
        logstore = get(var"#CURRENT_LOGSTORE")
        if logstore === nothing
            return write(DEFAULT_STDOUT[], x)
        else
            return write(something(logstore)::IOContext{IOStream}, x)
        end
    end

    @eval function Base.write(io::Union{ReTestItemsCapturingIO,IOContext{ReTestItemsCapturingIO}}, x::$(T)...)
        logstore = get(var"#CURRENT_LOGSTORE")
        if logstore === nothing
            return write(DEFAULT_STDOUT[], x...)
        else
            return write(something(logstore)::IOContext{IOStream}, x...)
        end
    end
end

# Note the original state pertaining to printing and logging and replace
# stdout and stderr with our STANDARD_IO_CONSUMER
function _setup_multithreaded_log_capture()
    if _not_compiling()
        @debugv 1 "Redirecting standard outputs to STANDARD_IO_CONSUMER"
        # this call is redundant as we already call it in runtests, but it is idempotent
        # and makes the multithtreded code self contained
        save_current_stdio()
        consumer = STANDARD_IO_CONSUMER
        logger = DEFAULT_LOGGER[]

        # approach adapted from https://github.com/JuliaLang/IJulia.jl/pull/667/files
        if :stream in propertynames(logger) && logger.stream == stderr
            new_logstate = Base.CoreLogging.LogState(typeof(logger)(consumer, logger.min_level))
            Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), new_logstate))
        end

        flush(stderr)
        flush(stdout)
        redirect_stdout(consumer)
        redirect_stderr(consumer)
    end
    return nothing
end

# Restores the original state pertaining to printing and logging
function _teardown_multithreaded_log_capture()
    if _not_compiling()
        @debugv 1 "Restoring original standard outputs"
        redirect_stdout(DEFAULT_STDOUT[])
        redirect_stderr(DEFAULT_STDERR[])

        logger = DEFAULT_LOGGER[]
        logstate = DEFAULT_LOGSTATE[]
        if :stream in propertynames(logger) && logger.stream == stderr
            Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), logstate))
        end
    end
    return nothing
end
