# runtests => JUnitTestSuites, containing `JUnitTestSuite`s (files)
# file     => JUnitTestSuite, containing `JUnitTestCase`s (testitems)
# testitem => JUnitTestCase, containing logs for any failure/errors
# Only include logs for testitems with failures/errors, to keep XML report size down.
export JUnitTestSuites, JUnitTestSuite, JUnitTestCase
export write_junit_file, write_junit_xml, junit_record!

# Field names match the name of the JUnit attributes e.g. `timestamp="..."`
mutable struct JUnitCounts
    timestamp::Union{DateTime,Nothing}  # Start time.
    time::Float64  # Duration in seconds.
    tests::Int     # Number of individual tests (`@test`, `@test_throws`, etc.)
    failures::Int
    errors::Int
    skipped::Int
end

JUnitCounts() = JUnitCounts(nothing, 0.0, 0, 0, 0, 0)

function JUnitCounts(ts::Test.DefaultTestSet)
    timestamp = unix2datetime(ts.time_start)
    time = isnothing(ts.time_end) ? 0.0 : (ts.time_end - ts.time_start)
    (; tests, failures, errors, skipped) = test_counts(ts)
    return JUnitCounts(timestamp, time, tests, failures, errors, skipped)
end


mutable struct JUnitTestCase  # TestItem run
    const name::String
    counts::JUnitCounts
    stats::Union{PerfStats, Nothing} # Additional stats not available from the testset
    error_message::Union{String,Nothing} # Additional message to include in `<error>`
    logs::Union{Vector{UInt8},Nothing} # Captured logs from a `@testitem`
end

function testcases(ti::TestItem)
    @assert !isempty(ti.testsets)
    @assert !isempty(ti.stats)
    @assert length(ti.testsets) == length(ti.stats)
    return [JUnitTestCase(ti, i) for i in 1:length(ti.testsets)]
end

function JUnitTestCase(ts::DefaultTestSet)
    name = ts.description
    counts = JUnitCounts(ts)
    return JUnitTestCase(name, counts, nothing, nothing, nothing)
end

function JUnitTestCase(ti::TestItem, run_number::Int)
    ts = ti.testsets[run_number]
    counts = JUnitCounts(ts)
    stats = ti.stats[run_number]
    if !ts.anynonpass
        logs = nothing
        message = nothing
    else
        io = IOBuffer()
        print_errors_and_captured_logs(io, ti, run_number)
        logs = take!(io)
        message = _error_message(ts, ti)
    end
    return JUnitTestCase(ti.name, counts, stats, message, logs)
end

function _error_message(fail::Test.Fail, ti)
    file = isnothing(fail.source.file) ? "unknown" : relpath(String(fail.source.file), ti.project_root)
    return string("Test failed at ", file, ":", fail.source.line)
end
function _error_message(err::Test.Error, ti)
    file = isnothing(err.source.file) ? "unknown" : relpath(String(err.source.file), ti.project_root)
    return string("Error during test at ", file, ":", err.source.line)
end
function _error_message(ts::Test.DefaultTestSet, ti)
    nonpass = _non_passes(ts)
    return if length(nonpass) == 1
        _error_message(only(nonpass), ti)
    else
        string("Multiple errors for test item at ", _file_info(ti))
    end
end

_non_passes(x::Test.Pass) = Test.Result[]
_non_passes(x::Test.Broken) = Test.Result[]  # Broken tests pass
_non_passes(x::Test.Fail) = [x]
_non_passes(x::Test.Error) = [x]
_non_passes(ts::Test.DefaultTestSet) = mapreduce(_non_passes, vcat, ts.results; init=Test.Result[])

mutable struct JUnitTestSuite  # File
    const name::String
    counts::JUnitCounts
    testcases::Vector{JUnitTestCase}
end
JUnitTestSuite(name::String) = JUnitTestSuite(name, JUnitCounts(), JUnitTestCase[])

mutable struct JUnitTestSuites
    const name::String
    counts::JUnitCounts
    testsuites::Vector{JUnitTestSuite}
end

JUnitTestSuites(name::String) = JUnitTestSuites(name, JUnitCounts(), JUnitTestSuite[])

function junit_record!(suites1::JUnitTestSuites, suites2::JUnitTestSuites)
    update!(suites1.counts, suites2.counts)
    append!(suites1.testsuites, suites2.testsuites)
end
function junit_record!(top::JUnitTestSuites, ts::JUnitTestSuite)
    update!(top.counts, ts.counts)
    push!(top.testsuites, ts)
end
function junit_record!(ts::JUnitTestSuite, tc::JUnitTestCase)
    update!(ts.counts, tc.counts)
    push!(ts.testcases, tc)
end
function junit_record!(ts::JUnitTestSuite, tcs::Vector{JUnitTestCase})
    foreach(tc -> junit_record!(ts, tc), tcs)
end
junit_record!(ts::JUnitTestSuite, ti::TestItem) = junit_record!(ts, testcases(ti))

update!(counts::JUnitCounts, ts::Test.DefaultTestSet) = update!(counts, JUnitCounts(ts))
function update!(counts1::JUnitCounts, counts2::JUnitCounts)
    if isnothing(counts1.timestamp)
        counts1.timestamp = counts2.timestamp
    end
    counts1.time += counts2.time
    counts1.tests += counts2.tests
    counts1.failures += counts2.failures
    counts1.errors += counts2.errors
    counts1.skipped += counts2.skipped
    return counts1
end

# "Broken" and "Skipped" are treated the same when in comes to reporting.
# The difference in Julia is "broken" tests are run and "skipped" tests are not run, but the
# Test.jl stdlib records them both as Broken (and in JUnit we record them both as skipped).
function test_counts(ts::Test.DefaultTestSet)
    tests = ts.n_passed
    failures = 0
    errors = 0
    skipped = 0
    for res in ts.results
        tests += res isa Test.Result
        failures += res isa Test.Fail
        errors += res isa Test.Error
        skipped += res isa Test.Broken
        if res isa Test.AbstractTestSet #Test.DefaultTestSet
            inner = test_counts(res)
            tests += inner.tests
            failures += inner.failures
            errors += inner.errors
            skipped += inner.skipped
        end
    end
    return (; tests, failures, errors, skipped)
end


###
### XML
###

function junit_path(proj, dir, junit)
    dir = get(ENV, "RETESTITEMS_REPORT_LOCATION", dir)
    timestamp = something(junit.counts.timestamp, now())
    time_str = format(timestamp, "yyyymmdd-HHMMSS")
    filename = isempty(proj) ? "report-$time_str.xml" : "report-$proj-$time_str.xml"
    return joinpath(dir, filename)
end

function write_junit_file(proj_name, dir, junit)
    path = junit_path(proj_name, dir, junit)
    return write_junit_file(path, junit)
end

# TestSuites or a single TestSuite can be a valid file
function write_junit_file(path::AbstractString, junit::Union{JUnitTestSuites,JUnitTestSuite})
    @info "Writing JUnit XML file to $(repr(path))"
    mkpath(dirname(path))
    open(path, "w") do io
        write_junit_file(io, junit)
    end
    return nothing
end

function write_junit_file(io::IO, junit::Union{JUnitTestSuites,JUnitTestSuite})
    write(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    write_junit_xml(io, junit)
    return nothing
end

function write_junit_xml(io, junit::JUnitTestSuites)
    write(io, "\n<testsuites")
    write_counts(io, junit.counts)
    write(io, ">")
    for ts in junit.testsuites
        write_junit_xml(io, ts)
    end
    write(io, "\n</testsuites>")
    return nothing
end

function write_junit_xml(io, ts::JUnitTestSuite)
    write(io, "\n<testsuite name=", xml_markup(ts.name))
    write_counts(io, ts.counts)
    write(io, ">")
    for tc in ts.testcases
        write_junit_xml(io, tc)
    end
    write(io, "\n</testsuite>")
    return nothing
end

function write_counts(io, x::JUnitCounts)
    timestamp = !isnothing(x.timestamp) ? format(x.timestamp, ISODateTimeFormat) : ""
    print(io,
        " timestamp=", repr(timestamp),
        " time=\"", round(x.time; digits=3), "\"",
        " tests=\"", x.tests, "\"",
        " skipped=\"", x.skipped, "\"",
        " failures=\"", x.failures, "\"",
        " errors=\"", x.errors, "\"",
    )
    return nothing
end

function write_dd_tags(io, x::PerfStats)
    # We don't record `elapsedtime`, since that already stored in the JUnitTestCase `time`.
    # Convert values from nanoseconds to seconds to match JUnit convention.
    gctime = x.gctime / 1e9
    compile_time = x.compile_time / 1e9
    recompile_time = x.recompile_time / 1e9
    eval_time = (x.elapsedtime / 1e9) - gctime - compile_time  # compile_time includes recompile_time
    write(io, "\n\t\t<properties>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.bytes]\" value=\"$(x.bytes)\"></property>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.allocs]\" value=\"$(x.allocs)\"></property>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.gctime]\" value=\"$(gctime)\"></property>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.compile_time]\" value=\"$(compile_time)\"></property>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.recompile_time]\" value=\"$(recompile_time)\"></property>")
    write(io, "\n\t\t<property name=\"dd_tags[perf.eval_time]\" value=\"$(eval_time)\"></property>")
    write(io, "\n\t\t</properties>")
    return nothing
end

function write_junit_xml(io, tc::JUnitTestCase)
    write(io, "\n\t<testcase name=", xml_markup(tc.name))
    write_counts(io, tc.counts)
    write(io, ">")
    !isnothing(tc.stats) && write_dd_tags(io, tc.stats)
    if !isnothing(tc.logs)
        write(io, "\n\t\t<error")
        !isnothing(tc.error_message) && write(io, " message=", xml_markup(tc.error_message))
        write(io, ">", xml_content(strip(String(tc.logs))))
        write(io, "\n\t\t</error>")
    end
    write(io, "\n\t</testcase>")
    return nothing
end

# make safe to appear in markup (i.e. between `< >`)
function xml_markup(x)
    return repr(replace(x,
        '\"' => "&quot;",
        '\'' => "&apos;",
        '<'  => "&lt;",
        '>'  => "&gt;",
        '&'  => "&amp;",
    ))
end

# make safe to appear in the contents (i.e. not markup)
function xml_content(x)
    return replace(x,
        # Try to strip ANSI color codes
        r"\e\[\d+m~?" => "",
        '<'  => "&lt;",
        '>'  => "&gt;",
        '&'  => "&amp;",
    )
end
