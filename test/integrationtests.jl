# This file is *integration* tests for `runtests`
# i.e. these tests exercise the full end-to-end public user interface.
# It relies on either
# - "test files" (in `test/testfiles/`) that use ReTestItems
#   - i.e. files using `@testitem` and `@testsetup` to define tests
#   - and which are run like `runtests("testfiles/foo_test.jl")
# - "packages" (in `test/packages/`) that use ReTestItems
#   - i.e. whole packages that have source code (dependencies, etc.) and which have tests
#     that use ReTestItems
#   - and which are run like `runtests("test/package/Foo.jl")`
#   - or with the `with_test_package` helper like `with_test_package(runtests, "Foo.jl")`
using ReTestItems, Pkg, Test

###
### Helpers
###

const _TEST_DIR = joinpath(pkgdir(ReTestItems), "test")
const TEST_FILES_DIR = joinpath(_TEST_DIR, "testfiles")
const TEST_PKG_DIR = joinpath(_TEST_DIR, "packages")

# Note "DontPass.jl" is handled specifically below, as it's the package which doesn't have
# passing tests. Other packages should pass tests and be added here:
const TEST_PKGS = ("NoDeps.jl", "TestsInSrc.jl", "TestProjectFile.jl", "TestEndExpr.jl")

include(joinpath(_TEST_DIR, "_integration_test_tools.jl"))

# Run `f` in the given package's environment and inside a `testset` which doesn't let
# the package's test failures/errors cause ReTestItems' tests to fail/error.
function with_test_package(f, name)
    return encased_testset() do
        cd(joinpath(TEST_PKG_DIR, name)) do
            Pkg.activate(".") do
                f()
            end
        end
    end
end

###
### Tests
###

@testset "integrationtests.jl" verbose=true begin

# test we can call runtests manually w/ directory
@testset "manual `runtests(dir)`" begin
    results = encased_testset() do
        runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl"))
    end
    @test n_passed(results) == 2  # NoDeps has two test files with a test each
end

@testset "manual `runtests(file)`" begin
    # test we can point to a file at the base of the package (not just in `src` or `test`)
    results = encased_testset() do
        runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl", "toplevel_tests.jl"))
    end
    @test n_passed(results) == 1
end

@testset "`runtests(path)` auto finds testsetups" begin
    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl
        runtests(joinpath(TEST_FILES_DIR, "_testitem_test.jl"))
    end
    @test n_passed(results) == 1

    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl in directory above
        runtests(joinpath(TEST_FILES_DIR, "_nested", "_testitem_test.jl"))
    end
    @test n_passed(results) == 1

    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl in directory above
        runtests(joinpath(TEST_FILES_DIR, "_nested"))
    end
    @test n_passed(results) == 1
end

@testset "Warn when not test file" begin
    pkg = joinpath(TEST_PKG_DIR, "TestsInSrc.jl")

    # warn if the path does not exist
    dne = joinpath(pkg, "does_not_exist")
    @test_logs (:warn, "No such path \"$dne\"") match_mode=:any begin
        runtests(dne)
    end

    # warn if the file is not a test file
    file = joinpath(pkg, "src", "foo.jl")
    @assert isfile(file)
    @test_logs (:warn, "\"$file\" is not a test file") match_mode=:any begin
        runtests(file)
    end

    # Warn for each invalid path
    @test_logs (:warn, "No such path \"$dne\"") (:warn, "\"$file\" is not a test file") match_mode=:any begin
        runtests(dne, file)
    end

    # Warn for each invalid path and still run valid ones
    test_file = joinpath(pkg, "src", "foo_test.jl")
    @assert isfile(test_file)
    results = @test_logs (:warn, "No such path \"$dne\"") (:warn, "\"$file\" is not a test file") match_mode=:any begin
        encased_testset() do
            runtests(test_file, dne, file)
        end
    end
    @test n_tests(results) == 2 # foo_test.jl has 2 tests
end

@testset "filter `runtests(func, x)`" begin
    pkg = joinpath(TEST_PKG_DIR, "TestsInSrc.jl")

    results = encased_testset() do
        runtests(pkg)
    end
    n_total = n_tests(results)
    @assert n_total > 0

    # can exclude everything
    results = encased_testset() do
        runtests(x->false, pkg)
    end
    @test n_tests(results) == 0

    # there is a `@testitem "bar"` -- filer to just that testitem.
    results = encased_testset() do
        runtests(ti -> contains(ti.name, "bar"), pkg)
    end
    @test n_passed(results) > 0
    @test n_tests(results) < n_total

    results = encased_testset() do
        runtests(ti -> contains(ti.name, "bar_"), pkg)
    end
    @test n_tests(results) == 0

    # there is a `bar_test.jl` -- filter to just that file.
    results = encased_testset() do
        runtests(ti -> contains(ti.file, "bar_"), pkg)
    end
    @test n_passed(results) > 0
    @test n_tests(results) < n_total

    # test we can filter by directory (all tests are in `src/`)
    results_test_dir = encased_testset() do
        runtests(ti -> startswith(ti.file, "$pkg/test"), pkg)
    end
    results_src_dir = encased_testset() do
        runtests(ti -> startswith(ti.file, "$pkg/src"), pkg)
    end
    @test n_tests(results_src_dir) == n_total
    @test n_tests(results_test_dir) == 0
end

@testset "`@testitem` scoping rules" begin
    results = encased_testset() do
        runtests(joinpath(TEST_FILES_DIR, "_scope_tests.jl"))
    end
    @test all_passed(results)
end

# running a project tests via Pkg also works
@testset "single-process" verbose=true begin
    # `Pkg.test()` runs in its own process, so will either return `nothing` or an error.
    @testset "Pkg.test() $pkg" for pkg in TEST_PKGS
        results = with_test_package(pkg) do
            Pkg.test()
        end
        @test all_passed(results)
    end
    @testset "Pkg.test() DontPass.jl" begin
        results = with_test_package("DontPass.jl") do
            Pkg.test()
        end
        @test length(non_passes(results)) > 0
    end

    # `runtests` runs in this process, so allows us to actually record the test results,
    # which means we can tests that runtests ran the tests we expected it to.
    @testset "runtests() $pkg" for pkg in TEST_PKGS
        if pkg == "TestEndExpr.jl"
            # TestEndExpr.jl requires `worker_init_expr` which isn't supported when nworkers=0.
            @test_skip with_test_package(pkg) do
                runtests()
            end
        else
            results = with_test_package(pkg) do
                runtests()
            end
            @test n_passed(results) > 0  # tests were found and ran
            @test all_passed(results)    # no tests failed/errored
        end
    end
    @testset "runtests() DontPass.jl" begin
        results = with_test_package("DontPass.jl") do
            runtests()
        end
        @test length(non_passes(results)) > 0
        # NOTE: These must be incremented when new failures/errors added to DontPass.jl.
        # println("\n\n\n\n\n\n")
        # @show length(non_passes(results)), length(failures(results)), length(errors(results))
        # println("\n\n\n\n\n\n")
        @test length(failures(results)) == 4
        @test length(errors(results)) == 9
    end
end

nworkers = 2
@testset "runtests with nworkers = $nworkers" verbose=true begin
    @testset "Pkg.test() $pkg" for pkg in TEST_PKGS
        results = with_test_package(pkg) do
            withenv("RETESTITEMS_NWORKERS" => nworkers) do
                Pkg.test()
            end
        end
        @test all_passed(results)
    end
    @testset "Pkg.test() DontPass.jl" begin
        results = with_test_package("DontPass.jl") do
            withenv("RETESTITEMS_NWORKERS" => 2) do
                Pkg.test()
            end
        end
        @test length(non_passes(results)) > 0
    end
end

@testset "don't recurse into subpackages" begin
if VERSION < v"1.9.0-"
    # The MonoRepo.jl setup requires Julia v1.9:
    # https://github.com/JuliaLang/Pkg.jl/commit/46f0de21dcfc5d1a3f4e6fbafe40462f88632359
    @warn "Skipping tests on MonoRepo.jl which requires Julia Version v1.9+" VERSION
    @test_broken false
else
    @testset "runtests" begin
        results = with_test_package("MonoRepo.jl") do
            runtests()
        end
        @test all_passed(results)
        # test we did in fact run just MonoRepo's tests.
        # MonoRepo.jl has 3 tests (and the subpackage C.jl has 2 tests).
        @test n_tests(results) == 3
    end
end
end

# Test that, starting in an env which has a local subpackage as a dependency,
# we can trigger that subpackage's tests and run them in the correct test env.
@testset "trigger subpackage tests" begin
if VERSION < v"1.9.0-"
    # The MonoRepo.jl setup requires Julia v1.9:
    # https://github.com/JuliaLang/Pkg.jl/commit/46f0de21dcfc5d1a3f4e6fbafe40462f88632359
    @warn "Skipping tests on MonoRepo.jl which requires Julia Version v1.9+" VERSION
    @test_broken false
else
    # `MonoRepo.jl` depends on the local package `C`.
    # `C.jl` has a test-only dependency that's not in the `MonoRepo.jl` Manifest.toml,
    # so C's tests will fail if we don't activate C's test environment.
    @testset "Pkg.test" begin
        results = with_test_package("MonoRepo.jl") do
            Pkg.test("C")
        end
        @test all_passed(results)
    end
    @testset "runtests" begin
        # `runtests` expects a Module or a directory path, not a module name as a string.
        path_to_C = abspath(joinpath(TEST_PKG_DIR, "MonoRepo.jl", "monorepo_packages", "C"))
        @assert isdir(path_to_C)
        results = with_test_package("MonoRepo.jl") do
            runtests(path_to_C)
        end
        @test all_passed(results)
        # test we did in fact run C's tests. C.jl has 2 tests.
        @test n_tests(results) == 2
    end
end # VERSION
end

@testset "passing file (not dir)" begin
    results = with_test_package("TestsInSrc.jl") do
        runtests("src/bar_tests.jl")
    end
    @test n_tests(results) == 4  # src/bar_test.jl has 4 tests
end

@testset "passing multiple files/dirs" begin
    # dir and file
    results = with_test_package("TestsInSrc.jl") do
        runtests("src/bar_tests.jl", "test")
    end
    @test n_tests(results) == 4  # src/bar_test.jl has 4 tests, test has none
    # order should not matter
    results = with_test_package("TestsInSrc.jl") do
        runtests("test", "src/bar_tests.jl")
    end
    @test n_tests(results) == 4

    # multiple files
    results = with_test_package("TestsInSrc.jl") do
        runtests("src/foo_test.jl", "src/bar_tests.jl")
    end
    @test n_tests(results) == 2 + 4  # foo_test.jl has 2, bar_test.jl has 4

    # with filter function
    results = with_test_package("TestsInSrc.jl") do
        runtests("src/foo_test.jl", "src/bar_tests.jl") do ti
            contains(ti.name, "bar")
        end
    end
    @test n_tests(results) == 4
end

@testset "print report sorted" begin
    # Test that the final summary has testitems by file, with files sorted alphabetically
    using IOCapture
    # verbose_results=true
    testset = with_test_package("TestsInSrc.jl") do
        runtests(verbose_results=true)
    end
    c = IOCapture.capture() do
        Test.print_test_results(testset)
    end
    # Test with `contains` rather than `match` so failure print an informative message.
    @test contains(
        c.output,
        r"""
        Test Summary:                     \| Pass  Total  Time
        TestsInSrc                        \|   13     13  \s*\d*.\ds
          src                             \|   13     13  \s*
            src/a_dir                     \|    6      6  \s*
              src/a_dir/a1_test.jl        \|    1      1  \s*
                a1                        \|    1      1  \s*\d*.\ds
              src/a_dir/a2_test.jl        \|    2      2  \s*
                a2                        \|    2      2  \s*\d*.\ds
                  a2_testset              \|    1      1  \s*\d*.\ds
              src/a_dir/x_dir             \|    3      3  \s*
                src/a_dir/x_dir/x_test.jl \|    3      3  \s*
                  z                       \|    1      1  \s*\d*.\ds
                  y                       \|    1      1  \s*\d*.\ds
                  x                       \|    1      1  \s*\d*.\ds
            src/b_dir                     \|    1      1  \s*
              src/b_dir/b_test.jl         \|    1      1  \s*
                b                         \|    1      1  \s*\d*.\ds
            src/bar_tests.jl              \|    4      4  \s*
              bar                         \|    4      4  \s*\d*.\ds
                bar values                \|    2      2  \s*\d*.\ds
            src/foo_test.jl               \|    2      2  \s*
              foo                         \|    2      2  \s*\d*.\ds
        """
    )
    # verbose_results=false
    testset = with_test_package("TestsInSrc.jl") do
        runtests(verbose_results=false)
    end
    c = IOCapture.capture() do
        Test.print_test_results(testset)
    end
    m = match(
        r"""
        Test Summary: \| Pass  Total  Time
        TestsInSrc    \|   13     13  \s*\d*.\ds
        """,
        c.output
    )
    @test m.match == c.output
end

@testset "`verbose_results`, `debug` and `logs` keywords" begin
    using IOCapture
    orig = ReTestItems.DEFAULT_STDOUT[]
    for logs in (:batched, :issues, :eager), debug in (true, false), verbose_results in (true, false)
        try
            c = IOCapture.capture() do
                with_test_package("NoDeps.jl") do
                    runtests(; logs, debug, verbose_results)
                end
            end
            # Test we have the expected log messages
            if logs in (:batched, :eager)
                @test contains(c.output, "tests done")
            else
                @test !contains(c.output, "tests done")
            end
            if debug
                @test contains(c.output, "Debug:")
            else
                @test !contains(c.output, "Debug:")
            end
            # Test we have the expected summary table
            testset = c.value
            c2 = IOCapture.capture() do
                Test.print_test_results(testset)
            end
            if verbose_results
                @test contains(c2.output, "NoDeps-testitem")
                @test contains(c2.output, "inner-testset")
            else
                @test !contains(c2.output, "NoDeps-testitem")
                @test !contains(c2.output, "inner-testset")
            end
        finally
            ReTestItems.DEFAULT_STDOUT[] = orig
        end
    end
end

@testset "`report=true` is not compatible with `logs=:eager`" begin
    @test_throws ArgumentError runtests("", report=true, logs=:eager)
end

@testset "filter `runtests(x; tags)`" begin
    file = joinpath(TEST_FILES_DIR, "_filter_tests.jl")
    # These testitems are expected in the file
    # @testitem "Test item no tags"
    # @testitem "Test item tag1"      tags=[:tag1]
    # @testitem "Test item tag1 tag2" tags=[:tag1, :tag2]
    results = encased_testset(()->runtests(file))
    @assert n_tests(results) == 3


    results = encased_testset(()->runtests(file, tags=:tag1))
    @test n_tests(results) == 2

    results = encased_testset(()->runtests(file, tags=[:tag1]))
    @test n_tests(results) == 2

    results = encased_testset(()->runtests(file, tags=[:tag2]))
    @test n_tests(results) == 1

    results = encased_testset(()->runtests(file, tags=[:tag2, :tag1]))
    @test n_tests(results) == 1

    results = encased_testset(()->runtests(file, tags=@view [:tag2, :tag1][1:2]))
    @test n_tests(results) == 1

    # There is no test with tag3
    results = encased_testset(()->runtests(file, tags=[:tag1, :tag3]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, tags=[:tag3]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, tags=:tag3))
    @test n_tests(results) == 0
end

@testset "filter `runtests(x; name)`" begin
    file = joinpath(TEST_FILES_DIR, "_filter_tests.jl")
    # These testitems are expected in the file
    # @testitem "Test item no tags"
    # @testitem "Test item tag1"      tags=[:tag1]
    # @testitem "Test item tag1 tag2" tags=[:tag1, :tag2]
    results = encased_testset(()->runtests(file))
    @assert n_tests(results) == 3

    results = encased_testset(()->runtests(file, name=""))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, name="Test item no tags"))
    @test n_tests(results) == 1

    results = encased_testset(()->runtests(file, name=@view "Test item no tags"[begin:end]))
    @test n_tests(results) == 1

    results = encased_testset(()->runtests(file, name=r"No such name in that file"))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, name=r"Test item"))
    @test n_tests(results) == 3

    results = encased_testset(()->runtests(file, name=r"tag[^s]"))
    @test n_tests(results) == 2

    results = encased_testset(()->runtests(file, name=r"tag2|tags"))
    @test n_tests(results) == 2
end

@testset "filter `runtests(x; name, tags)`" begin
    file = joinpath(TEST_FILES_DIR, "_filter_tests.jl")
    # These testitems are expected in the file
    # @testitem "Test item no tags"
    # @testitem "Test item tag1"      tags=[:tag1]
    # @testitem "Test item tag1 tag2" tags=[:tag1, :tag2]
    results = encased_testset(()->runtests(file))
    @assert n_tests(results) == 3


    results = encased_testset(()->runtests(file, name="", tags=Symbol[]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, name=r".", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, name="", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(file, name=r".", tags=Symbol[]))
    @test n_tests(results) == 3

    results = encased_testset(()->runtests(file, name=r"tag1", tags=:tag1))
    @test n_tests(results) == 2

    results = encased_testset(()->runtests(file, name=r"tag2", tags=[:tag1]))
    @test n_tests(results) == 1

    results = encased_testset(()->runtests(file, name=r"tag1", tags=[:tag2, :tag2]))
    @test n_tests(results) == 1
end

@testset "filter `runtests(func, x; name, tags)`" begin
    file = joinpath(TEST_FILES_DIR, "_filter_tests.jl")
    # These testitems are expected in the file
    # @testitem "Test item no tags"
    # @testitem "Test item tag1"      tags=[:tag1]
    # @testitem "Test item tag1 tag2" tags=[:tag1, :tag2]
    results = encased_testset(()->runtests(file))
    @assert n_tests(results) == 3

    results = encased_testset(()->runtests(ti-> false, file, name="", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> false, file, name="", tags=Symbol[]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> false, file, name=r".", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> true, file, name="", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> true, file, name="", tags=Symbol[]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> true, file, name=r".", tags=:tag3))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> false, file, name=r".", tags=Symbol[]))
    @test n_tests(results) == 0

    results = encased_testset(()->runtests(ti-> true, file, name=r".", tags=Symbol[]))
    @test n_tests(results) == 3
end

@testset "Warn on empty test set -- integration test" begin
    @test_logs (:warn, """
    Test item "Warn on empty test set -- integration test" at test/testfiles/_empty_testsets_tests.jl:1 contains test sets without tests:
    "Empty testset"
    "Inner empty testset"
    """) match_mode=:any begin
        ReTestItems.runtests(joinpath(TEST_FILES_DIR, "_empty_testsets_tests.jl"))
    end
end

@testset "log capture for an errored TestSetup" begin
    c = IOCapture.capture() do
        results = with_test_package("DontPass.jl") do
            runtests("test/error_in_setup_test.jl"; nworkers=1)
        end
    end
    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
    SetupThatErrors msg
    """,
    replace(c.output, r" on worker \d+" => ""))

    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
    SetupThatErrors msg
    """,
    replace(c.output, r" on worker \d+" => ""))

    # Since the test setup never succeeds it will be run mutliple times. Here we test
    # that we don't accumulate logs from all previous failed attempts (which would get
    # really spammy if the test setup is used by 100 test items).
    @test !occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        replace(c.output, r" on worker \d+" => "")
    )
    @test !occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        replace(c.output, r" on worker \d+" => "")
    )
end

@testset "test crashing testitem" begin
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_abort_tests.jl")
    # NOTE: this test must run with exactly 1 worker, so that we can test that the worker
    # is replaced after the abort and subsequent testitems still run.
    nworkers = 1
    @assert nworkers == 1
    # avoid crash logs escaping to stdout, as it confuses PkgEval
    # https://github.com/JuliaTesting/ReTestItems.jl/issues/38
    c = IOCapture.capture() do
        encased_testset(()->runtests(file; nworkers, debug=2, retries=0))
    end
    results = c.value
    @test n_tests(results) == 2
    @test n_passed(results) == 1
    # Test the error is as expected
    err = only(non_passes(results))
    @test err.test_type == :nontest_error
    @test err.value == string(ErrorException("Worker process aborted (signal=6) running test item \"Abort\" (run=1)"))
end

@testset "test retrying failing testitem" begin
    file = joinpath(TEST_FILES_DIR, "_retry_tests.jl")
    # This directory must match what's set in `_retry_tests`
    # Use `/tmp` directly instead of `mktemp` to remove chance that files are cleaned up
    # as soon as the worker process crashes.
    tmpdir = joinpath("/tmp", "JL_RETESTITEMS_TEST_TMPDIR")
    # must run with `testitem_timeout < 20` for test to timeout as expected.
    # and must run with `nworkers > 0` for retries to be supported.
    results = encased_testset(()->runtests(file; nworkers=1, retries=2, testitem_timeout=3))
    # Test we _ran_ each test-item the expected number of times
    read_count(x) = parse(Int, read(x, String))
    # Passes on second attempt, so only need to retry once.
    @test read_count(joinpath(tmpdir, "num_runs_1")) == 2
    # Doesn't pass til third attempt, so needs both retries.
    @test read_count(joinpath(tmpdir, "num_runs_2")) == 3
    # Doesn't pass ever, so need all retries. This testitem set `retries=4` which is greater
    # than the `retries=2` that `runtests` set, so we should retry 4 times.
    @test read_count(joinpath(tmpdir, "num_runs_3")) == 5
    # Doesn't pass ever, so need all retries. This testitem set `retries=1` which is less
    # than the `retries=2` that `runtests` set, so we should retry 2 times.
    @test read_count(joinpath(tmpdir, "num_runs_4")) == 3
    # Times out always, so should retry as many times as allowed.
    # Since it will be a new worker for each retry, we write one file for each.
    @test count(contains("num_runs_5"), readdir(tmpdir)) == 3
    # Times out on first run, then passes on second attempt.
    @test count(contains("num_runs_6"), readdir(tmpdir)) == 2

    # Test we _report_ the expected number of test-items
    @test n_tests(results) == 6
    # Testitems 1, 2, and 6 pass on retry.
    @test n_passed(results) == 3

    # Clear out any files created by this testset
    foreach(readdir(tmpdir; join=true)) do tmp
        # `force` in case it gets cleaned up between `readdir` and `rm`
        contains(tmp, "num_runs") && rm(tmp; force=true)
    end
    rm(tmpdir; force=true)
end

@testset "testitem timeout" begin
    file = joinpath(TEST_FILES_DIR, "_timeout_tests.jl")
    # NOTE: this test must run with exactly 1 worker, so that we can test that the worker
    # is replaced after the timeout and subsequent testitems still run.
    nworkers = 1
    @assert nworkers == 1
    results = encased_testset(()->runtests(file; nworkers, debug=1, testitem_timeout=4.0))
    @test n_tests(results) == 2
    @test n_passed(results) == 1
    # Test the error is as expected
    err = only(non_passes(results))
    @test err.test_type == :nontest_error
    @test err.value == string(ErrorException("Timed out after 4s running test item \"Test item takes 60 seconds\" (run=1)"))
end

@testset "testitem timeout set via env variable" begin
    file = joinpath(TEST_FILES_DIR, "_timeout_tests.jl")
    # NOTE: this test must run with exactly 1 worker, so that we can test that the worker
    # is replaced after the timeout and subsequent testitems still run.
    nworkers = 1
    @assert nworkers == 1
    results = withenv("RETESTITEMS_TESTITEM_TIMEOUT" => "4.0") do
        encased_testset(()->runtests(file; nworkers, debug=1))
    end
    @test n_tests(results) == 2
    @test n_passed(results) == 1
    # Test the error is as expected
    err = only(non_passes(results))
    @test err.test_type == :nontest_error
    @test err.value == string(ErrorException("Timed out after 4s running test item \"Test item takes 60 seconds\" (run=1)"))
end

@testset "Error outside `@testitem`" begin
    @test_throws Exception runtests(joinpath(TEST_FILES_DIR, "_invalid_file1_test.jl"))
    @test_throws Exception runtests(joinpath(TEST_FILES_DIR, "_invalid_file2_test.jl"))
end

@testset "`runtests` finds no testitems" begin
    file = joinpath(TEST_FILES_DIR, "_empty_file_test.jl")
    for nworkers in (0, 1)
        results = encased_testset(()->runtests(file; nworkers))
        @test n_tests(results) == 0
    end
end

# https://github.com/JuliaTesting/ReTestItems.jl/issues/49
@testset "Worker log capture on a failing test is not reported twice" begin
    test_file_path = joinpath(TEST_FILES_DIR, "_failing_test.jl")

    captured = IOCapture.capture(rethrow=Union{}) do
        encased_testset(()->runtests(test_file_path, nworkers=1, logs=:issues))
    end

    @test count("No Captured Logs", captured.output) == 1
end

if isdefined(Base.Threads, :nthreadpools)
    @testset "Worker and nworker_threads argument" begin
        test_file_path = joinpath(TEST_FILES_DIR, "_nworker_threads_test.jl")
        results = encased_testset(()->runtests(test_file_path; nworkers=1, nworker_threads="3,2"))
        @test n_passed(results) == 2
    end
else
    @warn "Skipping tests with interactive threadpool support which requires Julia Version v1.9+" VERSION
end

@testset "_redirect_logs and custom loggers" begin
    test_file_path = joinpath(TEST_FILES_DIR, "_logging_test.jl")
    captured = IOCapture.capture(rethrow=Union{}) do
        encased_testset(()->runtests(
            "test/testfiles/_logging_test.jl",
            nworkers=1,
            logs=:issues,
            worker_init_expr=:(using Logging; Logging.global_logger(Logging.ConsoleLogger(stderr)))
        ))
    end
    # The test passes so we shouldn't see any logs
    @test !occursin("Info message from testitem", captured.output)
end

@testset "error on code outside `@testitem`/`@testsetup`" begin
    err_msg = "Test files must only include `@testitem` and `@testsetup` calls."
    expected = VERSION < v"1.8" ? Exception : err_msg
    @test_throws expected runtests(joinpath(TEST_FILES_DIR, "_misuse_file1_test.jl"))
    @test_throws expected runtests(joinpath(TEST_FILES_DIR, "_misuse_file2_test.jl"))
    @test_throws expected runtests(joinpath(TEST_FILES_DIR, "_misuse_file3_test.jl"))
end

@testset "Duplicate names in same file throws" begin
    file = joinpath(TEST_FILES_DIR, "_duplicate_names_test.jl")
    expected_msg = Regex("Duplicate test item name `dup` in file `test/testfiles/_duplicate_names_test.jl` at line 4")
    @test_throws expected_msg runtests(file; nworkers=0)
    @test_throws expected_msg runtests(file; nworkers=1)
end
@testset "Duplicate names in different files allowed" begin
    file1 = joinpath(TEST_FILES_DIR, "_same_name1_test.jl")
    file2 = joinpath(TEST_FILES_DIR, "_same_name2_test.jl")
    for nworkers in (0, 1)
        results = encased_testset(() -> runtests(file1, file2; nworkers))
        @test n_tests(results) == 2
    end
end

@testset "Duplicate IDs not allowed" begin
    file = joinpath(TEST_FILES_DIR, "_duplicate_id_test.jl")
    err_msg = r"Test item IDs must be unique. ID `dup` used for test items: \"name1\" at .* and \"name2\" at .*"
    expected = VERSION < v"1.8" ? ErrorException : err_msg
    @test_throws expected runtests(file; nworkers=0)
    @test_throws expected runtests(file; nworkers=1)
end

@testset "Timeout failures accurately record elapsed time" begin
    timeout = 3
    results = encased_testset() do
        runtests(joinpath(TEST_FILES_DIR, "_timeout_tests.jl"); nworkers=1, testitem_timeout=timeout)
    end
    # unwrap results down to the testset for the timed-out testitem to check its elapsed time
    results = only(results.results) # test
    results = only(results.results) # test/testfiles
    results = only(results.results) # test/testfiles/_timeout_tests.jl
    ts = results.results[1]
    @assert ts.description == "Test item takes 60 seconds"
    @test ts.time_end - ts.time_start ≈ timeout
end

@testset "worker always crashes immediately" begin
    file = joinpath(TEST_FILES_DIR, "_happy_tests.jl")

    # We have occassionally seen the Process exist with the expected signal.
    @assert typemin(Int32) == -2147483648
    terminated_err_log_1 = r"Error: Worker\(pid=\d+, terminated=true, termsignal=(6|-2147483648)\) terminated unexpectedly. Starting new worker process \(retry 1/2\)."
    terminated_err_log_2 = r"Error: Worker\(pid=\d+, terminated=true, termsignal=(6|-2147483648)\) terminated unexpectedly. Starting new worker process \(retry 2/2\)."

    worker_init_expr = :(@eval ccall(:abort, Cvoid, ()))
    # We don't use IOCapture for capturing logs as that seems to hang when the worker crashes.
    mktemp() do io, path
        results = redirect_stdio(stdout=io, stderr=io, stdin=devnull) do
            encased_testset() do
                runtests(file; nworkers=2, worker_init_expr)
            end
        end
        captured = read(path, String)
        # Test we retried starting a worker twice and saw the expected log each time.
        @test contains(captured, terminated_err_log_1)
        @test contains(captured, terminated_err_log_2)
        # Test that `runtests` errored overall, before any test items were run.
        @test n_tests(results) == 1
        @test length(errors(results)) == 1
    end
end

@testset "worker crashes immediately but succeeds on retry" begin
    file = joinpath(TEST_FILES_DIR, "_happy_tests.jl")
    mktemp() do crash_io, _
        # At least one worker should crash, but all workers should succeed upon a retry.
        worker_init_expr = quote
            if isempty(read($crash_io))
                write($crash_io, "1")
                @eval ccall(:abort, Cvoid, ())
            end
        end
        # We have occassionally seen the Process exist with the expected signal.
        @assert typemin(Int32) == -2147483648
        terminated_err_log_1 = r"Error: Worker\(pid=\d+, terminated=true, termsignal=(6|-2147483648)\) terminated unexpectedly. Starting new worker process \(retry 1/2\)."
        # We don't use IOCapture for capturing logs as that seems to hang when the worker crashes.
        mktemp() do log_io, _
            results = redirect_stdio(stdout=log_io, stderr=log_io, stdin=devnull) do
                encased_testset() do
                    runtests(file; nworkers=2, worker_init_expr)
                end
            end
            captured = read(log_io, String)
            # Test we saw a worker crash and retried starting the worker.
            @test contains(captured, terminated_err_log_1)
            # Test we were then able to run all tests successfully.
            @test n_tests(results) == 3
            @test all_passed(results) == 1
        end
    end
end

@testset "test_end_expr" begin
    # `_happy_tests.jl` has 3 testitems with 1 passing test each.
    file = joinpath(TEST_FILES_DIR, "_happy_tests.jl")
    # Test that running a `test_end_expr` after each testitem works;
    # should work exactly the same no matter if we use workers or not.
    @testset "nworkers=$nworkers" for nworkers in (0, 1, 2)
        @testset "post-testitem checks pass" begin
            # Here there should be two extra passing tests per testitem.
            test_end1 = quote
                @test 1 == 1
                @test 2 == 2
            end
            results1 = encased_testset() do
                runtests(file; nworkers, test_end_expr=test_end1)
            end
            @test n_tests(results1) == 9
            @test all_passed(results1)
        end

        @testset "post-testitem checks fail" begin
            # Here there should be one extra failing tests per testitem.
            test_end2 = quote
                @test 1 == 2
            end
            results2 = encased_testset() do
                runtests(file; nworkers, test_end_expr=test_end2)
            end
            @test n_tests(results2) == 6
            @test n_passed(results2) == 3
            @test length(failures(results2)) == 3
        end
    end
    @testset "report printing" begin
        using IOCapture
        # Test that a passing `test_end_expr` we just report the total number of tests
        # including the extra tests, which here is an extra 1 test per testitem.
        test_end3 = quote @test true end
        results3 = encased_testset() do
            runtests(file; nworkers=1, test_end_expr=test_end3)
        end
        c3 = IOCapture.capture() do
            Test.print_test_results(results3)
        end
        @assert n_tests(results3) == 6
        @assert all_passed(results3)
        @test contains(
            c3.output,
            r"""
            Test Summary: \| Pass  Total  Time
            ReTestItems   \|    6      6  \d.\ds
            """
        )
        # Test that for a failing `test_end_expr` we report the failing tests, including
        # the `@testset` which we have put inside the `test_end_expr`.
        test_end4 = quote
            @testset "post-testitem" begin
                @test false
            end
        end
        results4 = encased_testset() do
            runtests(file; nworkers=1, test_end_expr=test_end4)
        end
        @test n_tests(results4) == 6
        @test n_passed(results4) == 3
        c4 = IOCapture.capture() do
            Test.print_test_results(results4)
        end
        @test contains(
            c4.output,
            r"""
            Test Summary:                        \| Pass  Fail  Total  Time
            ReTestItems                          \|    3     3      6  \d.\ds
            """
        )
        @test contains(
            c4.output,
            r"""
            \s*    happy 1                      \|    1     1      2  \d.\ds
            \s*      post-testitem              \|          1      1  \d.\ds
            """
        )
    end
    @testset "TestEndExpr.jl package" begin
        # Test that the TestEndExpr.jl package passes without the `test_end_expr`
        # checking for danginling pins.
        worker_init_expr = quote
            using TestEndExpr: init_pager!
            init_pager!()
        end
        results_no_end = with_test_package("TestEndExpr.jl") do
            runtests(; nworkers=1, worker_init_expr)
        end
        @test all_passed(results_no_end)
        # Test that the TestEndExpr.jl package fails when we add the `test_end_expr`
        # checking for danginling pins.
        test_end_expr = quote
            using TestEndExpr: GLOBAL_PAGER, count_pins
            p = GLOBAL_PAGER[]
            (isnothing(p) || isempty(p.pages)) && return nothing
            @testset "no pins left at end of test" begin
                @test count_pins(p) == 0
            end
        end
        results_with_end = with_test_package("TestEndExpr.jl") do
            runtests(; nworkers=1, worker_init_expr, test_end_expr)
        end
        @test !all_passed(results_with_end)
        @test n_passed(results_with_end) ≥ 1
        @test length(failures(results_with_end)) ≥ 1
    end
end

@testset "Replace workers when we hit memory threshold" begin
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_happy_tests.jl")
    try
        # monkey-patch the internal `memory_percent` function to return a fixed value, so we
        # can control if we hit the `memory_threshold`.
        @eval ReTestItems.memory_percent() = 83.1
        expected_warning = "Warning: Memory usage (83.1%) is higher than threshold (7.0%). Restarting worker process to try to free memory."

        # Pass `memory_threshold` keyword, and hit the memory threshold.
        c1 = IOCapture.capture() do
            encased_testset(()->runtests(file; nworkers=1, memory_threshold=0.07))
        end
        results1 = c1.value
        @test all_passed(results1)
        @test contains(c1.output, expected_warning)

        # Set the `RETESTITEMS_MEMORY_THRESHOLD` env variable, and hit the memory threshold.
        c2 = IOCapture.capture() do
            withenv("RETESTITEMS_MEMORY_THRESHOLD" => 0.07) do
                encased_testset(()->runtests(file; nworkers=1))
            end
        end
        results2 = c2.value
        @test all_passed(results2)
        @test contains(c2.output, expected_warning)

        # Set the memory_threshold, but don't hit it.
        c3 = IOCapture.capture() do
            withenv("RETESTITEMS_MEMORY_THRESHOLD" => 0.9) do
                encased_testset(()->runtests(file; nworkers=1))
            end
        end
        results3 = c3.value
        @test all_passed(results3)
        @test !contains(c3.output, expected_warning)
    finally
        @eval ReTestItems.memory_percent() = 100 * Float64(Sys.maxrss()/Sys.total_memory())
    end
    xx = 99
    err_msg = "ArgumentError: `memory_threshold` must be between 0 and 1, got $xx"
    expected_err = VERSION < v"1.8" ? ArgumentError : err_msg
    @test_throws expected_err runtests(file; nworkers=1, memory_threshold=xx)
end

end # integrationtests.jl testset
