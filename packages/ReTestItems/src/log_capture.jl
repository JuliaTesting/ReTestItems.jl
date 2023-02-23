const DEFAULT_STDOUT = Ref{IO}()
const DEFAULT_STDERR = Ref{IO}()
const DEFAULT_LOGSTATE = Ref{Base.CoreLogging.LogState}()
const DEFAULT_LOGGER = Ref{Base.CoreLogging.AbstractLogger}()

"""
    _capture_logs(f, ti::TestItem)

Redirects stdout and stderr to an `IOBuffer` inside of `ti`.
For multithreaded test executors, this requires `_setup_multithreaded_log_capture()` to be called beforehand.

The Multithreaded case won't properly capture logs if the evaluated test code modifies global
logstate -- this would make the context variable unreachable to that part of the code.
A workaround would be to use `ContextVariablesX.with_logger` or to switch to a distributed executor.
"""
function _capture_logs(f, ti::TestItem)
    if !(nthreads() > 1 && nprocs() == 1)
        # Distributed or single-process & single-threaded executor case
        redirect_logs_to_iobuffer(ti.logstore) do
            f()
        end
    else
        # Multithreaded executor case
        ContextVariablesX.with_context(var"#CURRENT_TESTITEM" => ti) do
            f()
        end
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
_on_worker() = nprocs() == 1 ? "" : " on worker $(myid())"
_on_worker(ti::TestItem) = nprocs() == 1 ? "" : " on worker $(ti.workerid[])"
_file_info(ti::TestItem) = string(relpath(ti.file, ti.project_root), ":", ti.line)

"""
    print_errors_and_captured_logs(ti::TestItem, ts::DefaultTestSet; verbose=false)

When a testitem doesn't succeed, we print the corresponding error/failure reports
from the testset and any logs that we captured while the testitem was eval()'d.

When `verbose` is `true`, any captured logs are printed regardless of test result status.

Nothing is printed when no logs were captures and no failures or errors occured.
"""
function print_errors_and_captured_logs(ti::TestItem, ts::DefaultTestSet; verbose=false)
    has_errors = ts.anynonpass
    has_logs = ti.logstore.size > 0
    if has_errors || verbose
        report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
        has_logs && _print_captured_logs(report_iob, ti)
        has_errors && _print_test_errors(report_iob, ts, _on_worker(ti))
        if has_errors || has_logs
            # a newline to visually separate the report for the current test item
            println(report_iob)
            # Printing in one go to minimize chance of mixing with other concurrent prints
            @loglock write(DEFAULT_STDOUT[], take!(report_iob.io))
        end
    end
    return nothing
end

function _print_captured_logs(io, ti::TestItem)
    if ti.logstore.size > 0
        printstyled(io, "Captured logs"; bold=true, color=Base.info_color())
        print(io, " for test item $(repr(ti.name)) at ")
        printstyled(io, _file_info(ti); bold=true, color=:default)
        println(io, _on_worker(ti))
        # Not consuming the buffer with take! to make testing log capture easier
        write(io, ti.logstore.data)
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
    printstyled(report_iob, "STALLED"; bold=true)
    print(report_iob, " test item $(repr(ti.name)) at ")
    printstyled(report_iob, _file_info(ti); bold=true, color=:default)
    println(report_iob, _on_worker(ti))
    # Let's also print any logs we might have collected for the stalled test item
    _print_captured_logs(report_iob, ti)
    ti.logstore.size > 0 && println(report_iob)
    @loglock write(DEFAULT_STDOUT[], take!(report_iob.io))
end

# Marks the start of each test item
function log_running(ti::TestItem)
    report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
    printstyled(report_iob, "RUNNING"; bold=true)
    print(report_iob, " test item $(repr(ti.name)) at ")
    printstyled(report_iob, _file_info(ti); bold=true, color=:default)
    println(report_iob, _on_worker(ti))
    @loglock write(DEFAULT_STDOUT[], take!(report_iob.io))
end

### Log capture for multithreaded executor #################################################

struct ReTestItemsCapturingIO <: IO end
const STANDARD_IO_CONSUMER = ReTestItemsCapturingIO()

function Base.isopen(::ReTestItemsCapturingIO)
    isnothing(get(var"#CURRENT_TESTITEM")) ? isopen(DEFAULT_STDOUT[]) : true
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

# When the #CURRENT_TESTITEM is set, we redirect all writes that would normally go to stdout
# to an iobuffer local to the testitem. This way we achieve log capture while using multithreaded
# test executors. Sadly, context variables are not visible when logstate gets changed by the
# tested code in which case we recommend to use distributed executors or to use
# `ContextVariablesX.with_logger` instead.
ContextVariablesX.@contextvar var"#CURRENT_TESTITEM"::TestItem;
for T in (UInt8, Vector{UInt8}, String, Char, AbstractChar, AbstractString, IO)
    @eval function Base.write(io::Union{ReTestItemsCapturingIO,IOContext{ReTestItemsCapturingIO}}, x::$(T))
        ti = get(var"#CURRENT_TESTITEM")
        if ti === nothing
            return write(DEFAULT_STDOUT[], x)
        else
            return write((something(ti)::TestItem).logstore, x)
        end
    end

    @eval function Base.write(io::Union{ReTestItemsCapturingIO,IOContext{ReTestItemsCapturingIO}}, x::$(T)...)
        ti = get(var"#CURRENT_TESTITEM")
        if ti === nothing
            return write(DEFAULT_STDOUT[], x...)
        else
            return write((something(ti)::TestItem).logstore, x...)
        end
    end
end

# Note the original state pertaining to printing and logging and replace
# stdout and stderr with our STANDARD_IO_CONSUMER
function _setup_multithreaded_log_capture()
    if _not_compiling()
        @debugv 1 "Redirecting standard outputs to STANDARD_IO_CONSUMER"
        DEFAULT_STDERR[] = stderr
        DEFAULT_STDOUT[] = stdout
        DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
        DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger
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

### Log capture for distributed / single-threaded case #####################################

# Adapted from IOCapture.jl and Suppressor.jl MIT licensed packages
function redirect_logs_to_iobuffer(f, io)
    if _not_compiling()
        # Save the default output streams.
        original_stderr = stderr
        original_stdout = stdout
        DEFAULT_STDERR[] = original_stderr
        DEFAULT_STDOUT[] = original_stdout
        DEFAULT_LOGSTATE[] = Base.CoreLogging._global_logstate
        DEFAULT_LOGGER[] = Base.CoreLogging._global_logstate.logger

        pipe = Pipe()
        Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
        @static if VERSION >= v"1.6.0-DEV.481" # https://github.com/JuliaLang/julia/pull/36688
            temp_stdout = IOContext(pipe.in, :color => get(stdout, :color, false))
            temp_stderr = IOContext(pipe.in, :color => get(stderr, :color, false))
        else
            temp_stdout = pipe.in
            temp_stderr = pipe.in
        end
        errmon(@spawn Base.write(io, pipe))

        # approach adapted from https://github.com/JuliaLang/IJulia.jl/pull/667/files
        logstate = Base.CoreLogging._global_logstate
        logger = logstate.logger
        if :stream in propertynames(logger) && logger.stream == original_stderr
            new_logstate = Base.CoreLogging.LogState(typeof(logger)(temp_stderr, logger.min_level))
            Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), new_logstate))
        end
        flush(stderr)
        flush(stdout)
        redirect_stdout(temp_stdout)
        redirect_stderr(temp_stderr)
    end

    try
        f()
    finally
        if _not_compiling()
            flush(temp_stdout)
            flush(temp_stderr)
            redirect_stdout(original_stdout)
            redirect_stderr(original_stderr)
            # It is generally not safe to close the pipe see:
            # https://github.com/JuliaIO/Suppressor.jl/issues/48
            # close(pipe)

            if :stream in propertynames(logger) && logger.stream == stderr
                Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), logstate))
            end
        end
    end
end
