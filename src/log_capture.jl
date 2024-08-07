const LOG_DISPLAY_MODES = (:eager, :issues, :batched)

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

# A lock that helps to stagger prints to DEFAULT_STDOUT, used in `print_errors_and_captured_logs`
# which is called by multiple tasks on the coordinator
const LogCaptureLock = ReentrantLock()
macro loglock(expr)
    return :(@lock LogCaptureLock $(esc(expr)))
end

function default_log_display_mode(report::Bool, nworkers::Integer, interactive::Bool=Base.isinteractive())
    @assert nworkers >= 0
    if interactive
        if report || nworkers > 1
            return :batched
        else
            return :eager
        end
    else
        return :issues
    end
end

# Adapted from timing.jl
const _cnt_units = ["", " K", " M", " B", " T", " P"]
const _mem_pow10_units = ["byte", "KB", "MB", "GB", "TB", "PB"]
function _format_pow10_bytes(bytes)
    bytes, mb = Base.prettyprint_getunits(bytes, length(_mem_pow10_units), Int64(1000))
    if mb == 1
        return string(Int(bytes), " ", _mem_pow10_units[mb], bytes==1 ? "" : "s")
    else
        return string(Base.Ryu.writefixed(Float64(bytes), 3), " ", _mem_pow10_units[mb])
    end
end
function _print_scaled_one_dec(io, value, scale, label="")
    @assert scale > 0
    value_scaled = Float64(value/scale)
    if 0.1 > value_scaled > 0
        print(io, "<0.1")
    elseif value_scaled >= 0.1
        print(io, Base.Ryu.writefixed(value_scaled, 1))
    else
        print(io, "0")
    end
    print(io, label)
end
function print_time(io; elapsedtime, bytes=0, gctime=0, allocs=0, compile_time=0, recompile_time=0)
    _print_scaled_one_dec(io, elapsedtime, 1e9, " secs")
    if  gctime > 0 || compile_time > 0
        print(io, " (")
        if compile_time > 0
            _print_scaled_one_dec(io, 100 * compile_time, elapsedtime, "% compile")
        end
        if recompile_time > 0
            print(io, ", ")
            _print_scaled_one_dec(io, 100 * recompile_time, elapsedtime, "% recompile")
        end
        if gctime > 0
            compile_time > 0 && print(io, ", ")
            _print_scaled_one_dec(io, 100 * gctime, elapsedtime, "% GC")
        end
        print(io, ")")
    end
    if bytes > 0
        print(io, ", ")
        allocs, ma = Base.prettyprint_getunits(allocs, length(_cnt_units), Int64(1000))
        if ma == 1
            print(io, Int(allocs), _cnt_units[ma], allocs==1 ? " alloc " : " allocs ")
        else
            print(io, Base.Ryu.writefixed(Float64(allocs), 2), _cnt_units[ma], " allocs ")
        end
        print(io, "(", _format_pow10_bytes(bytes), ")")
    end
end

function logfile_name(ti::TestItem, i=nothing)
    # Replacing reserved chars https://en.wikipedia.org/wiki/Filename
    # File name should remain unique due to the inclusion of `ti.number`.
    safe_name = replace(ti.name, r"[/\\\?%\*\:\|\"\<\>\.\,\;\=\s\$\#\@]" => "_")
    i = something(i, length(ti.testsets) + 1)  # Separate log file for each retry.
    return string("ReTestItems_test_", first(safe_name, 150), "_", ti.number[], "_", i, ".log")
end
function logfile_name(ts::TestSetup)
    # Test setup names should be unique to begin with, but we add hash of their location to be sure
    string("ReTestItems_setup_", ts.name, "_", hash(ts.file, UInt(ts.line)), ".log")
end
logpath(ti::TestItem, i=nothing) = joinpath(RETESTITEMS_TEMP_FOLDER[], logfile_name(ti, i))
logpath(ts::TestSetup) = joinpath(RETESTITEMS_TEMP_FOLDER[], logfile_name(ts))

"""
    _redirect_logs(f, target::Union{IO,String})

Redirects stdout and stderr while `f` is evaluated to `target`.
If target is String it is assumed it is a file path.
"""
_redirect_logs(f, path::String) = open(io->_redirect_logs(f, io), path, "w")
function _redirect_logs(f, target::IO)
    target === DEFAULT_STDOUT[] && return f()
    # If we're not doing :eager logs, make sure the displaysize is large so we don't truncate
    # CPU profiles.
    colored_io = IOContext(target, :color => get(DEFAULT_STDOUT[], :color, false), :displaysize => (10000,10000))
    # In case the default logger was changed by the user, we need to make sure the new logstate
    # is poinitng to the new stderr.
    # Adapted from https://github.com/JuliaIO/Suppressor.jl/blob/cbfc46f1450b03d6b69dad4c35de739290ff0aff/src/Suppressor.jl#L158-L161
    logstate = Base.CoreLogging._global_logstate
    logger = logstate.logger
    should_replace_logstate = :stream in propertynames(logger) && logger.stream == stderr
    if should_replace_logstate
        new_logstate = Base.CoreLogging.LogState(typeof(logger)(colored_io, logger.min_level))
        Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), new_logstate))
    end
    try
        redirect_stdio(f, stdout=colored_io, stderr=colored_io)
    finally
        if should_replace_logstate
            Core.eval(Base.CoreLogging, Expr(:(=), :(_global_logstate), logstate))
        end
    end
end


### Logging and reporting helpers ##########################################################

_on_worker() = " on worker $(Libc.getpid())"
_on_worker(ti::TestItem) = " on worker $(last(ti.workerid))"
_file_info(ti::Union{TestSetup,TestItem}) = string(relpath(ti.file, ti.project_root), ":", ti.line)
_has_logs(ts::TestSetup) = filesize(logpath(ts)) > 0
# The path might not exist if a testsetup always throws an error and we don't get to actually
# evaluate the test item.
_has_logs(ti::TestItem, i=nothing) = (path = logpath(ti, i); (isfile(path) && filesize(path) > 0))
# Stats to help diagnose OOM issues.
_mem_watermark() = string(
    # Tracks the peak memory usage of a process / worker
    "maxrss ", lpad(Base.Ryu.writefixed(maxrss_percent(), 1), 4),
    # Total memory pressure on the machine
    "% | mem ", lpad(Base.Ryu.writefixed(memory_percent(), 1), 4),
    "% | "
)
maxrss_percent() = 100 * Float64(Sys.maxrss()/Sys.total_memory())
memory_percent() = 100 * Float64(1 - (Sys.free_memory()/Sys.total_memory()))

"""
    print_errors_and_captured_logs(ti::TestItem, run_number::Int; logs=:batched, errors_first=false)

When a testitem doesn't succeed, we print the corresponding error/failure reports
from the testset and any logs that we captured while the testitem was eval()'d.

For `:eager` mode of `logs` we don't print any logs as they bypass log capture. `:batched`
means we print logs even for passing test items, whereas `:issues` means we are only printing
captured logs if there were any errors or failures.

If `errors_first=true`, then the test errors are printed first and the logs second.
The default `errors_first=false`, prints the logs firsts.

Nothing is printed when no logs were captures and no failures or errors occured.
"""
print_errors_and_captured_logs(ti::TestItem, run_number::Int; kwargs...) =
    print_errors_and_captured_logs(DEFAULT_STDOUT[], ti, run_number; kwargs...)
function print_errors_and_captured_logs(
    io, ti::TestItem, run_number::Int; logs=:batched, errors_first::Bool=false,
)
    ts = ti.testsets[run_number]
    has_errors = any_non_pass(ts)
    has_logs = _has_logs(ti, run_number) || any(_has_logs, ti.testsetups)
    if has_errors || logs == :batched
        report_iob = IOContext(IOBuffer(), :color=>Base.get_have_color())
        println(report_iob)
        # in :eager mode, the logs were already printed
        if errors_first
            has_errors && _print_test_errors(report_iob, ts, _on_worker(ti))
            logs != :eager && _print_captured_logs(report_iob, ti, run_number)
        else
            logs != :eager && _print_captured_logs(report_iob, ti, run_number)
            has_errors && _print_test_errors(report_iob, ts, _on_worker(ti))
        end
        if has_errors || has_logs
            # a newline to visually separate the report for the current test item
            println(report_iob)
            # Printing in one go to minimize chance of mixing with other concurrent prints
            @loglock write(io, take!(report_iob.io))
        end
    end
    # If we have errors, keep the tesitem log file for JUnit report.
    !has_errors && rm(logpath(ti, run_number), force=true)
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

# Calling this function directly will always print *something* for the test item, either
# the captured logs or a messgage that no logs were captured. `print_errors_and_captured_logs`
# will call this function only if some logs were collected or when called with `verbose_results`.
function _print_captured_logs(io, ti::TestItem, run_number::Int)
    for setup in ti.testsetups
        _print_captured_logs(io, setup, ti)
    end
    has_logs = _has_logs(ti, run_number)
    bold_text = has_logs ? "Captured Logs" : "No Captured Logs"
    printstyled(io, bold_text; bold=true, color=Base.info_color())
    print(io, " for test item $(repr(ti.name)) at ")
    printstyled(io, _file_info(ti); bold=true, color=:default)
    println(io, _on_worker(ti))
    has_logs && open(logpath(ti, run_number), "r") do logstore
        write(io, logstore)
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

function print_state(io, state, ti, ntestitems; color=:default)
    interactive = parse(Bool, get(ENV, "RETESTITEMS_INTERACTIVE", string(Base.isinteractive())))
    print(io, format(now(), "HH:MM:SS | "))
    !interactive && print(io, _mem_watermark())
    if ntestitems > 0
        # rpad/lpad so that the eval numbers are all vertically aligned
        printstyled(io, rpad(uppercase(state), 5); bold=true, color)
        print(io, " (", lpad(ti.eval_number[], ndigits(ntestitems)), "/", ntestitems, ")")
    else
        printstyled(io, uppercase(state); bold=true)
    end
    print(io, " test item $(repr(ti.name)) ")
end

function print_file_info(io, ti)
    print(io, "at ")
    printstyled(io, _file_info(ti); bold=true, color=:default)
end

function log_testitem_skipped(ti::TestItem, ntestitems=0)
    io = IOContext(IOBuffer(), :color => get(DEFAULT_STDOUT[], :color, false)::Bool)
    print_state(io, "SKIP", ti, ntestitems; color=Base.warn_color())
    print_file_info(io, ti)
    println(io)
    write(DEFAULT_STDOUT[], take!(io.io))
end

# Marks the start of each test item
function log_testitem_start(ti::TestItem, ntestitems=0)
    io = IOContext(IOBuffer(), :color => get(DEFAULT_STDOUT[], :color, false)::Bool)
    print_state(io, "START", ti, ntestitems)
    print_file_info(io, ti)
    println(io)
    write(DEFAULT_STDOUT[], take!(io.io))
end

function log_testitem_done(ti::TestItem, ntestitems=0)
    io = IOContext(IOBuffer(), :color => get(DEFAULT_STDOUT[], :color, false)::Bool)
    print_state(io, "DONE", ti, ntestitems)
    x = last(ti.stats) # always print stats for most recent run
    print_time(io; x.elapsedtime, x.bytes, x.gctime, x.allocs, x.compile_time, x.recompile_time)
    println(io)
    write(DEFAULT_STDOUT[], take!(io.io))
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
