using ReTestItems, Pkg, Test

const _TEST_DIR = joinpath(pkgdir(ReTestItems), "test")
const TEST_PKG_DIR = joinpath(_TEST_DIR, "packages")

# Note "DontPass.jl" is handled specifically below, as it's the package which doesn't have
# passing tests. Other packages should pass tests and be added here:
const TEST_PKGS = ("NoDeps.jl", "TestsInSrc.jl")

include(joinpath(_TEST_DIR, "integration_test_tools.jl"))

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

# test we can call runtests manually w/ directory
@testset "manual `runtests(dir)`" begin
    results = encased_testset() do
        runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl"))
    end
    @test n_passed(results) == 1  # NoDeps has a single test
end

@testset "`runtests(path)` auto finds testsetups" begin
    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl
        runtests(joinpath(_TEST_DIR, "_testitem_test.jl"))
    end
    @test n_passed(results) == 1

    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl in directory above
        runtests(joinpath(_TEST_DIR, "_nested", "_testitem_test.jl"))
    end
    @test n_passed(results) == 1

    results = encased_testset() do
        # relies on testsetup in _testitem_testsetup.jl in directory above
        runtests(joinpath(_TEST_DIR, "_nested"))
    end
    @test n_passed(results) == 1
end

@testset "Warn when not test file" begin
    pkg = joinpath(TEST_PKG_DIR, "TestsInSrc.jl")

    # warn if the path does not exist
    dne = joinpath(pkg, "does_not_exist")
    @test_logs (:warn, "No such path \"$dne\"") begin
        runtests(dne)
    end

    # warn if the file is not a test file
    file = joinpath(pkg, "src", "foo.jl")
    @assert isfile(file)
    @test_logs (:warn, "\"$file\" is not a test file") begin
        runtests(file)
    end

    # Warn for each invalid path
    @test_logs (:warn, "No such path \"$dne\"") (:warn, "\"$file\" is not a test file") begin
        runtests(dne, file)
    end

    # No warning for valid test files
    test_file = joinpath(pkg, "src", "foo_test.jl")
    @assert isfile(test_file)
    results = @test_logs begin
        encased_testset() do
            runtests(test_file)
        end
    end
    @test n_tests(results) == 2 # foo_test.jl has 2 tests

    # No warning for directories (so long as they exist)
    dir = joinpath(pkg, "test")
    @assert isdir(dir)
    results = @test_logs begin
        encased_testset() do
            runtests(dir)
        end
    end
    @test n_tests(results) == 0 # TestsInSrc.jl/test/ has no tests

    # Warn for each invalid path and still run valid ones
    results = @test_logs (:warn, "No such path \"$dne\"") (:warn, "\"$file\" is not a test file") begin
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
        runtests(joinpath(_TEST_DIR, "_scope_tests.jl"))
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
        results = with_test_package(pkg) do
            runtests()
        end
        @test n_passed(results) > 0  # tests were found and ran
        @test all_passed(results)    # no tests failed/errored
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

const nworkers = 2
@testset "Distributed (--procs=$(nworkers))" verbose=true begin
    julia_args = ["--procs", string(nworkers)]
    @testset "Pkg.test() $pkg" for pkg in TEST_PKGS
        results = with_test_package(pkg) do
            Pkg.test(; julia_args)
        end
        @test all_passed(results)
    end
    @testset "Pkg.test() DontPass.jl" begin
        results = with_test_package("DontPass.jl") do
            Pkg.test(; julia_args)
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
    results = with_test_package("TestsInSrc.jl") do
        runtests()
    end
    testset = only(results.results) # unwrap the TestsInSrc testset
    c = IOCapture.capture() do
        Test.print_test_results(testset)
        ## Should look like (possibly with different Time values):
        # Test Summary:                     | Pass  Total  Time
        # TestsInSrc                        |   13     13  0.0s
        #   src                             |   13     13
        #     src/a_dir                     |    6      6
        #       src/a_dir/a1_test.jl        |    1      1
        #         a1                        |    1      1  0.0s
        #       src/a_dir/a2_test.jl        |    2      2
        #         a2                        |    2      2  0.0s
        #       src/a_dir/x_dir             |    3      3
        #         src/a_dir/x_dir/x_test.jl |    3      3
        #           x                       |    1      1  0.0s
        #           y                       |    1      1  0.0s
        #           z                       |    1      1  0.0s
        #     src/b_dir                     |    1      1
        #       src/b_dir/b_test.jl         |    1      1
        #         b                         |    1      1  0.0s
        #     src/bar_tests.jl              |    4      4
        #       bar                         |    4      4  0.0s
        #     src/foo_test.jl               |    2      2
        #       foo                         |    2      2  0.0s
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
              src/a_dir/x_dir             \|    3      3  \s*
                src/a_dir/x_dir/x_test.jl \|    3      3  \s*
                  x                       \|    1      1  \s*\d*.\ds
                  y                       \|    1      1  \s*\d*.\ds
                  z                       \|    1      1  \s*\d*.\ds
            src/b_dir                     \|    1      1  \s*
              src/b_dir/b_test.jl         \|    1      1  \s*
                b                         \|    1      1  \s*\d*.\ds
            src/bar_tests.jl              \|    4      4  \s*
              bar                         \|    4      4  \s*\d*.\ds
            src/foo_test.jl               \|    2      2  \s*
              foo                         \|    2      2  \s*\d*.\ds
        """
    )
end

@testset "`verbose` and `debug` keywords" begin
    using IOCapture
    orig = ReTestItems.DEFAULT_STDOUT[]
    for verbose in (true, false), debug in (true, false)
        try
            c = IOCapture.capture() do
                with_test_package("NoDeps.jl") do
                    runtests(; verbose=verbose, debug=debug)
                end
            end
            # Test we have the expected log messages
            if verbose
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
            results = c.value
            testset = only(results.results) # unwrap the NoDeps testset
            c2 = IOCapture.capture() do
                Test.print_test_results(testset)
            end
            if verbose
                @test contains(c2.output, "inner-testset")
            else
                @test !contains(c2.output, "inner-testset")
            end
        finally
            ReTestItems.DEFAULT_STDOUT[] = orig
        end
    end
end

@testset "filter `runtests(x; tags)`" begin
    file = joinpath(_TEST_DIR, "_filter_tests.jl")
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
    file = joinpath(_TEST_DIR, "_filter_tests.jl")
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
    file = joinpath(_TEST_DIR, "_filter_tests.jl")
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
    file = joinpath(_TEST_DIR, "_filter_tests.jl")
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
    Test item "Warn on empty test set -- integration test" at test/_empty_testsets_tests.jl:4 contains test sets without tests:
    "Empty testset"
    "Inner empty testset"
    """) match_mode=:any begin
        ReTestItems.runtests(joinpath(_TEST_DIR, "_empty_testsets_tests.jl"))
    end
end

@testset "log capture for an errored TestSetup" begin
    c = IOCapture.capture() do
        results = with_test_package("DontPass.jl") do
            runtests("test/error_in_setup_test.jl")
        end
    end
    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
    SetupThatErrors msg
    """,
    c.output)

    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
    SetupThatErrors msg
    """,
    c.output)

    # Since the test setup never succeeds it will be evaluated mutliple times. Here we test
    # that we don't accumulate logs from all previous failed attempts (which would get
    # really spammy if the test setup is used by 100 test items).
    good_test_has_two_logs = occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        c.output
    )
    bad_test_has_two_logs = occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1mtest/error_in_setup_test.jl:1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        c.output
    )
    @test !good_test_has_two_logs && !bad_test_has_two_logs
end
