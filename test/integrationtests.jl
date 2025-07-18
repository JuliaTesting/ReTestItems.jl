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
    using IOCapture
    c = IOCapture.capture() do
        encased_testset(() -> runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl")))
    end
    results = c.value
    @test n_passed(results) == 2  # NoDeps has two test files with a test each
    @test contains(c.output, "[ Tests Completed: 2/2 test items were run.")
end

@testset "manual `runtests(file)`" begin
    # test we can point to a file at the base of the package (not just in `src` or `test`)
    using IOCapture
    c = IOCapture.capture() do
        encased_testset(() -> runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl", "toplevel_tests.jl")))
    end
    results = c.value
    @test n_passed(results) == 1
    @test contains(c.output, "[ Tests Completed: 1/1 test items were run.")
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

@testset "Warn or error when not test file" begin
    using ReTestItems: NoTestException
    pkg = joinpath(TEST_PKG_DIR, "TestsInSrc.jl")

    # warn if the path does not exist
    dne = joinpath(pkg, "does_not_exist")
    dne_msg = "No such path $(repr(dne))"
    @test_logs (:warn, dne_msg) match_mode=:any begin
        runtests(dne)
    end
    # throw if `validate_paths`
    @test_throws NoTestException(dne_msg) runtests(dne; validate_paths=true)
    # test setting `validate_paths` via environment variable
    withenv("RETESTITEMS_VALIDATE_PATHS" => 1) do
        @test_throws NoTestException(dne_msg) runtests(dne)
    end

    # warn if the file is not a test file
    file = joinpath(pkg, "src", "foo.jl")
    @assert isfile(file)
    file_msg = "$(repr(file)) is not a test file"
    @test_logs (:warn, file_msg) match_mode=:any begin
        runtests(file)
    end
    # throw if `validate_paths`
    @test_throws NoTestException(file_msg) runtests(file; validate_paths=true)

    # Warn for each invalid path
    @test_logs (:warn, dne_msg) (:warn, file_msg) match_mode=:any begin
        runtests(dne, file)
    end
    # Throw on first invalid path if `validate_paths`
    @test_throws NoTestException(dne_msg) runtests(dne, file; validate_paths=true)
    @test_throws NoTestException(file_msg) runtests(file, dne; validate_paths=true)

    # Warn for each invalid path and still run valid ones
    test_file = joinpath(pkg, "src", "foo_test.jl")
    @assert isfile(test_file)
    results = @test_logs (:warn, "No such path $(repr(dne))") (:warn, "$(repr(file)) is not a test file") match_mode=:any begin
        encased_testset() do
            runtests(test_file, dne, file)
        end
    end
    @test n_tests(results) == 2 # foo_test.jl has 2 tests
    # Throw on first invalid path, even if some are valid, if `validate_paths`
    @test_throws NoTestException(dne_msg) runtests(test_file, dne, file; validate_paths=true)
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

    # there is a `@testitem "bar"` -- filter to just that testitem.
    results = encased_testset() do
        runtests(ti -> contains(ti.name, "bar"), pkg)
    end
    @test n_passed(results) > 0
    @test n_tests(results) < n_total

    @test_throws ReTestItems.NoTestException runtests(ti -> contains(ti.name, "bar_"), pkg)

    # there is a `@testitem "b"` tagged `:b_tag` -- filter to just that testitem.
    results = encased_testset() do
        runtests(ti -> :b_tag in ti.tags, pkg)
    end
    @test n_passed(results) == 1
    @test n_tests(results) == 1

    # combining with `name` and `tags` keyword
    results = encased_testset() do
        runtests(ti -> :b_tag in ti.tags, pkg; name="b")
    end
    @test n_passed(results) == 1
    @test n_tests(results) == 1

    results = encased_testset() do
        runtests(ti -> :b_tag in ti.tags, pkg; name="b", tags=:nope)
    end
    @test n_passed(results) == 0
    @test n_tests(results) == 0

    results = encased_testset() do
        runtests(ti -> :b_tag in ti.tags, pkg; name="nope")
    end
    @test n_passed(results) == 0
    @test n_tests(results) == 0

    ## TODO: Are we okay to remove these tests?
    ## passing a `shouldrun` function as the first arg has never been documented, and
    ## when it has come up as a workaround for people, we have only ever said you can filter
    ## on `ti.name` and `ti.tags`, so i think it is okay to remove these tests that use
    ## `ti.file` (and not support filtering on `ti.file)
    ##
    # # there is a `bar_test.jl` -- filter to just that file.
    # results = encased_testset() do
    #     runtests(ti -> contains(ti.file, "bar_"), pkg)
    # end
    # @test n_passed(results) > 0
    # @test n_tests(results) < n_total

    # # test we can filter by directory (all tests are in `src/`)
    # results_test_dir = encased_testset() do
    #     runtests(ti -> startswith(ti.file, "$pkg/test"), pkg)
    # end
    # results_src_dir = encased_testset() do
    #     runtests(ti -> startswith(ti.file, "$pkg/src"), pkg)
    # end
    # @test n_tests(results_src_dir) == n_total
    # @test n_tests(results_test_dir) == 0

    # can only filter on `ti.name` and `ti.tags` (at least for now)
    @test_throws "no field file" runtests(ti -> contains(ti.file, "bar_"), pkg)
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

@testset "runtests a dir with 0 nworkers but worker_init_expr set" verbose=true begin
    # Doesn't actually matter what it's set to, just that it's set.
    worker_init_expr =:(1+1)
    results = encased_testset() do
        runtests(joinpath(TEST_PKG_DIR, "NoDeps.jl"); worker_init_expr)
    end

    @test n_passed(results) == 0
    @test length(errors(results)) == 1
end

nworkers = 2
@testset "runtests with nworkers = $nworkers" verbose=true begin
    @testset "Pkg.test() $pkg" for pkg in TEST_PKGS
        c = IOCapture.capture() do
            with_test_package(pkg) do
                withenv("RETESTITEMS_NWORKERS" => nworkers) do
                    Pkg.test()
                end
            end
        end
        results = c.value
        @test all_passed(results)
        @test contains(c.output, "[ Tests Completed")
    end
    @testset "Pkg.test() DontPass.jl" begin
        c = IOCapture.capture() do
            with_test_package("DontPass.jl") do
                withenv("RETESTITEMS_NWORKERS" => 2) do
                    Pkg.test()
                end
            end
        end
        results = c.value
        @test length(non_passes(results)) > 0
        @test contains(c.output, "[ Tests Completed")
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
    if !Base.Sys.iswindows() # so we can hardcode filepaths to keep the test readable
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
    end
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
                @test contains(c.output, "DEBUG @")
            else
                @test !contains(c.output, "DEBUG @")
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
    @test_throws ReTestItems.NoTestException runtests(file, tags=[:tag1, :tag3])

    @test_throws ReTestItems.NoTestException runtests(file, tags=[:tag3])

    @test_throws ReTestItems.NoTestException runtests(file, tags=:tag3)
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
    fullpath = joinpath(TEST_FILES_DIR, "_empty_testsets_tests.jl")
    relfpath = relpath(fullpath, pkgdir(ReTestItems))
    @test_logs (:warn, """
    Test item "Warn on empty test set -- integration test" at $relfpath:1 contains test sets without tests:
    "Empty testset"
    "Inner empty testset"
    """) match_mode=:any begin
        ReTestItems.runtests(fullpath)
    end
end

@testset "log capture for an errored TestSetup" begin
    path = joinpath("test", "error_in_setup_test.jl")
    c = IOCapture.capture() do
        results = with_test_package("DontPass.jl") do
            runtests(path; nworkers=1)
        end
    end
if Base.Sys.iswindows()
    @test occursin(
        "\e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at",
        replace(c.output, r" on worker \d+" => "")
    )
else
    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1m$(path):1\e[22m
    SetupThatErrors msg
    """,
    replace(c.output, r" on worker \d+" => ""))

    @test occursin("""
    \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1m$(path):1\e[22m
    SetupThatErrors msg
    """,
    replace(c.output, r" on worker \d+" => ""))

    # Since the test setup never succeeds it will be run mutliple times. Here we test
    # that we don't accumulate logs from all previous failed attempts (which would get
    # really spammy if the test setup is used by 100 test items).
    @test !occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, good test\") at \e[39m\e[1m$(path):1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        replace(c.output, r" on worker \d+" => "")
    )
    @test !occursin("""
        \e[36m\e[1mCaptured logs\e[22m\e[39m for test setup \"SetupThatErrors\" (dependency of \"bad setup, bad test\") at \e[39m\e[1m$(path):1\e[22m
        SetupThatErrors msg
        SetupThatErrors msg
        """,
        replace(c.output, r" on worker \d+" => "")
    )
end # iswindows
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
    sig = Base.Sys.iswindows() ? 0 : 6
    @test err.value == string(ErrorException("Worker process aborted (signal=$(sig)) running test item \"Abort\" (run=1)"))
end

@testset "test retrying failing testitem" begin
    file = joinpath(TEST_FILES_DIR, "_retry_tests.jl")
    # This directory must match what's set in `_retry_tests`
    # Use `/tmp` directly instead of `mktemp` to remove chance that files are cleaned up
    # as soon as the worker process crashes.
    tmpdir = joinpath("/tmp", "JL_RETESTITEMS_TEST_TMPDIR")
    # must run with `testitem_timeout < 20` for test to timeout as expected.
    # and must run with `nworkers > 0` for retries to be supported.
    results = encased_testset(()->runtests(file; nworkers=1, retries=2, testitem_timeout=5))
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

# There was previously a bug where if `runtests` were called from inside another `@testset`
# and `nworkers=0`, then `retries` and `failfast` were ignored, i.e. failing testitems were
# not retried and did not cause the tests to stop, due to how we were checking whether or
# not a test had failed. Running `runtests` inside `encased_testset` was sufficient to
# reproduce this bug.
@testset "bugfix: `runtests` in a testset" begin
    using IOCapture
    # test `retries` works
    file = joinpath(TEST_FILES_DIR, "_failing_test.jl")
    c = IOCapture.capture() do
        encased_testset(() -> runtests(file, nworkers=0, retries=1))
    end
    @test contains(c.output, "Retrying")
    # test `failfast` works
    file = joinpath(TEST_FILES_DIR, "_failfast_failure_tests.jl")
    c = IOCapture.capture() do
        encased_testset(() -> runtests(file, nworkers=0, failfast=true))
    end
    @test contains(c.output, "[ Fail Fast: 2/3 test items were run.")
end


@testset "testitem_timeout" begin
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

    for t in (0, -1.1)
        expected = ArgumentError("`testitem_timeout` must be a positive number, got $t")
        @test_throws expected runtests(file; nworkers, testitem_timeout=t)
    end
end

@testset "testitem_timeout set via env variable" begin
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

@testset "@testitem `timeout`" begin
    # NOTE: this test must run with >0 worker
    # https://github.com/JuliaTesting/ReTestItems.jl/issues/87
    nworkers = 1
    # This file contains a single test that sets `timeout=6` and sleeps for 10 seconds.
    file = joinpath(TEST_FILES_DIR, "_timeout2_tests.jl")
    # The @testitem's own `timeout=6` should take precedence.
    # The test is partly relying on the error message accurately reflecting the actual behaviour...
    # so we test with a really big timeout so it would be obvious if the larger of the two
    # timeouts were to be used (in which case the test would fail as the testitem would pass).
    for testitem_timeout in (4, 8, 1_000_000)
        results = encased_testset(()->runtests(file; nworkers, testitem_timeout))
        @test n_tests(results) == 1
        @test n_passed(results) == 0
        # Test the error is as expected, namely that the timeout is 6 seconds.
        err = only(non_passes(results))
        @test err.test_type == :nontest_error
        @test err.value == string(ErrorException("Timed out after 6s running test item \"Sets timeout=6\" (run=1)"))
    end
end

@testset "Error outside `@testitem`" begin
    @test_throws Exception runtests(joinpath(TEST_FILES_DIR, "_invalid_file1_test.jl"))
    @test_throws Exception runtests(joinpath(TEST_FILES_DIR, "_invalid_file2_test.jl"))
end

@testset "`runtests` finds no testitems" begin
    file = joinpath(TEST_FILES_DIR, "_empty_file_test.jl")
    for nworkers in (0, 1)
        @test_throws ReTestItems.NoTestException runtests(file; nworkers)
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
    filter_func(ti) = false
    @test_throws err_msg runtests(joinpath(TEST_FILES_DIR, "_misuse_file1_test.jl"))
    @test_throws err_msg runtests(joinpath(TEST_FILES_DIR, "_misuse_file2_test.jl"))
    @test_throws err_msg runtests(joinpath(TEST_FILES_DIR, "_misuse_file3_test.jl"))
    @test_throws err_msg runtests(joinpath(TEST_FILES_DIR, "_misuse_file4_test.jl"), name="ti 1")
    @test_throws err_msg runtests(filter_func, joinpath(TEST_FILES_DIR, "_misuse_file4_test.jl"))

    # TODO: delete this when we drop our unofficial support for `___RAI_MACRO_NAME_DONT_USE`
    @testset "unofficial RAI support" begin
        # used in `_support_rai_test.jl`
        @assert ReTestItems.___RAI_MACRO_NAME_DONT_USE == Symbol("@test_rel")
        @eval begin
            macro test_rel(args...)
                local name::String
                local ex::Expr
                local tags = Symbol[]
                for arg in args
                    if arg.head == :(=) && arg.args[1] == :name
                        name = arg.args[2]
                    elseif arg.head == :(=) && arg.args[1] == :tags
                        tags = arg.args[2]
                    elseif arg.head == :(=) && arg.args[1] == :code
                        ex = arg.args[2]
                    end
                end
                quote
                    @testitem $(name) begin
                        using Test
                        $(ex)
                    end
                end
            end
        end
        file = joinpath(TEST_FILES_DIR, "_support_rai_test.jl")
        filter_func(ti) = false
        results = encased_testset(() -> runtests(file))
        @test n_tests(results) == 3
        results = encased_testset(() -> runtests(file; name="ti"))
        @test n_tests(results) == 1
        results = encased_testset(() -> runtests(file; name=r"other"))
        @test n_tests(results) == 2
        results = encased_testset(() -> runtests(file; tags=[:xyz]))
        @test n_tests(results) == 1
        @test_throws ReTestItems.NoTestException runtests(filter_func, file)
    end
end

@testset "Duplicate names in same file throws" begin
    file = joinpath(TEST_FILES_DIR, "_duplicate_names_test.jl")
    relfpath = relpath(file, pkgdir(ReTestItems))
    expected_msg = if Base.Sys.iswindows()
        Regex("Duplicate test item name `dup` in file")
    else
        Regex("Duplicate test item name `dup` in file `$(relfpath)` at line 4")
    end
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

@testset "CPU profile timeout trigger" begin
    using Profile
    # We're only testing that the signal was registered and that the stacktrace was printed.
    # We also tried testing that the CPU profile was displayed here, but that was too flaky in CI.
    function capture_timeout_profile(f, timeout_profile_wait; kwargs...)
        logs = mktemp() do path, io
            redirect_stdio(stdout=io, stderr=io, stdin=devnull) do
                encased_testset() do
                    if isnothing(timeout_profile_wait)
                        runtests(joinpath(TEST_FILES_DIR, "_timeout_tests.jl"); nworkers=1, testitem_timeout=3, kwargs...)
                    else
                        runtests(joinpath(TEST_FILES_DIR, "_timeout_tests.jl"); nworkers=1, testitem_timeout=3, timeout_profile_wait, kwargs...)
                    end
                end
            end
            flush(io)
            close(io)
            read(path, String)
        end
        f(logs)
        @assert occursin("timed out running test item \"Test item takes 60 seconds\" after 3 seconds", logs)
        return logs
    end

    if Base.Sys.iswindows()
        @testset "Windows not supported" begin
            capture_timeout_profile(1) do logs
                @test occursin("CPU profiles on timeout is not supported on Windows, ignoring `timeout_profile_wait`", logs)
            end
        end
    else
        @testset "timeout_profile_wait=0 means no CPU profile" begin
            capture_timeout_profile(0) do logs
                @test !occursin("Information request received", logs)
            end
        end

        default_peektime = Profile.get_peek_duration()
        @testset "non-zero timeout_profile_wait means we collect a CPU profile" begin
            capture_timeout_profile(5) do logs
                @test occursin("Information request received. A stacktrace will print followed by a $(default_peektime) second profile", logs)
                @test count(r"pthread_cond_wait|__psych_cvwait", logs) > 0 # the stacktrace was printed (will fail on Windows)
                @test occursin("Profile collected.", logs)
            end
        end


        @testset "`set_peek_duration` is respected in `worker_init_expr`" begin
            capture_timeout_profile(5, worker_init_expr=:(using Profile; Profile.set_peek_duration($default_peektime + 1.0))) do logs
                @test occursin("Information request received. A stacktrace will print followed by a $(default_peektime + 1.0) second profile", logs)
                @test count(r"pthread_cond_wait|__psych_cvwait", logs) > 0 # the stacktrace was printed (will fail on Windows)
                @test occursin("Profile collected.", logs)
            end
        end


        # The RETESTITEMS_TIMEOUT_PROFILE_WAIT environment variable can be used to set the timeout_profile_wait.
        @testset "RETESTITEMS_TIMEOUT_PROFILE_WAIT environment variable" begin
            withenv("RETESTITEMS_TIMEOUT_PROFILE_WAIT" => "5") do
                capture_timeout_profile(nothing) do logs
                    @test occursin("Information request received", logs)
                    @test count(r"pthread_cond_wait|__psych_cvwait", logs) > 0 # the stacktrace was printed (will fail on Windows)
                    @test occursin("Profile collected.", logs)
                end
            end
        end

        # The profile is collected for each worker thread.
        @testset "CPU profile with $(repr(log_capture))" for log_capture in (:eager, :batched)
            capture_timeout_profile(5, nworker_threads=VERSION >= v"1.9" ? "3,2" : "3", logs=log_capture) do logs
                @test occursin("Information request received", logs)
                @test count(r"pthread_cond_wait|__psych_cvwait", logs) > 0 # the stacktrace was printed (will fail on Windows)
                @test occursin("Profile collected.", logs)
            end
        end
    end # iswindows
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
mutable struct AtomicCounter{T}; @atomic x::T; end
@testset "test_end_expr always runs, even if testitem throws" begin
    @testset "DontPass.jl package" begin
        # Test that even though the tests in DontPass will fail, the test_end_expr will
        # still run.
        end_expr_count = AtomicCounter(0)
        test_end_expr = quote
            @info "RUNNING"
            @atomic $end_expr_count.x += 1
        end
        dont_pass_results = with_test_package("DontPass.jl") do
            runtests(; nworkers=0, test_end_expr)
        end
        @test !all_passed(dont_pass_results)
        @show n_passed(dont_pass_results)
        @show length(failures(dont_pass_results))
        @show length(errors(dont_pass_results))
        Test.print_test_results(dont_pass_results)
        # This is the total number of testitems in DontPass.jl, minus those with
        # nonexistent testsetups, or errors in the testsetup.
        @test @atomic(end_expr_count.x) == 7
    end
end

@testset "Replace workers when we hit memory threshold" begin
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_happy_tests.jl")
    try
        # monkey-patch the internal `memory_percent` function to return a fixed value, so we
        # can control if we hit the `memory_threshold`.
        @eval ReTestItems.memory_percent() = 83.1
        expected_warning = "Warning: Memory usage (83.1%) is higher than threshold (7.0%). Restarting process for worker 1 to try to free memory."

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

@testset "skipping testitems" begin
    # Test report printing has test items as "skipped" (which appear under "Broken")
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_skip_tests.jl")
    results = encased_testset(()->runtests(file; nworkers=1))
    c = IOCapture.capture() do
        Test.print_test_results(results)
    end
    @test contains(
        c.output,
        r"""
        Test Summary: \s*     \| Pass  Fail  Broken  Total  Time
        ReTestItems   \s*     \|    4     1       3      8  \s*\d*.\ds
        """
    )
end

@testset "logs are aligned" begin
    file = joinpath(TEST_FILES_DIR, "_skip_tests.jl")
    c1 = IOCapture.capture() do
        encased_testset(()->runtests(file))
    end
    @test contains(c1.output, r"START \(1/6\) test item \"no skip, 1 pass\"")
    @test contains(c1.output, r"DONE  \(1/6\) test item \"no skip, 1 pass\"")
    @test contains(c1.output, r"SKIP  \(3/6\) test item \"skip true\"")
end

@testset "ParseError in test file" begin
    file = joinpath(TEST_FILES_DIR, "_parse_error_test.jl")
    # the actual error type will be a TaskFailedException, containing a LoadError,
    # containing a ParseError, but what we care about is that ultimately the ParseError is
    # displayed, so we just check for that.
    # Only v1.10+ has the newer Parser with better error messages.
    expected = VERSION < v"1.10" ? "syntax:" : ["ParseError:", "Expected `]`"]
    @test_throws expected runtests(file; nworkers=0)
    @test_throws expected runtests(file; nworkers=1)
end

@testset "invalid testitem combined with filter function" begin
    # When filtering testitems from the AST (i.e. before evaluating the `@testitem` macro)
    # we need to be sure *not to filter out incorrect usages of `@testitem`* and make sure
    # these still throw errors.
    # Note: filtering testitems can still mask some issues that would appear if all
    # testitems were run, such as having testitems with duplicate names in the same,
    for file in (
        "_bad_tags1_test.jl",
        "_bad_tags2_test.jl",
        "_bad_name1_test.jl",
        "_bad_name2_test.jl",
        "_bad_name3_test.jl",
        "_invalid_file1_test.jl",
        "_invalid_file2_test.jl",
        "_misuse_file1_test.jl",
        "_misuse_file2_test.jl",
        "_misuse_file3_test.jl",
        "_misuse_file4_test.jl",
        "_parse_error_test.jl",
    )
        path = joinpath(TEST_FILES_DIR, file)
        # make sure the file throws when run in full...
        @test_throws Exception runtests(path)
        # ...and still throws even when filtering out all testitems
        @test_throws Exception runtests(Returns(false), path)
    end
end

# see https://github.com/JuliaTesting/ReTestItems.jl/issues/177
@testset "error code from running `@testitem` directly" begin
    filename = joinpath(TEST_FILES_DIR, "_direct_testitem.jl")
    cmd = `$(Base.julia_cmd()) --project $filename`
    p = run(pipeline(ignorestatus(cmd); stdout, stderr), wait=true)
    @test !success(p)
end

@testset "runtests `failfast` keyword" begin
    using IOCapture
    # Each file has 3 testitems, with the second test item "bad" failing in some way.
    @testset "$case" for (case, filename) in (
        :failure => "_failfast_failure_tests.jl",
        :error   => "_failfast_error_tests.jl",
        :timeout => "_failfast_timeout_tests.jl",
        :crash   => "_failfast_crash_tests.jl",
    )
        testitem_timeout = 5
        fullpath = joinpath(TEST_FILES_DIR, filename)
        relfpath = relpath(fullpath, pkgdir(ReTestItems))
        # For 0 or 1 workers, we expect to fail on the second testitem out of 3.
        # If running with 3 workers, then all 3 testitems will be running in parallel,
        # so we expect to see all 3 testitems run, even though one fails.
        @testset "nworkers=$nworkers" for nworkers in (0, 1, 3)
            # println("$case, $nworkers")
            if case in (:crash, :timeout) && nworkers == 0
                # if no workers, can't recover from a crash, and timeout not supported.
                @test_skip case
                continue
            end
            c = IOCapture.capture() do
                encased_testset(() -> runtests(fullpath; nworkers, testitem_timeout, retries=1, failfast=true))
            end
            results = c.value
            if nworkers == 3
                @test n_tests(results) == 3
                @test n_passed(results) == 2
            else
                @test n_tests(results) == 2
                @test n_passed(results) == 1
            end
            # @show c.output
            @test contains(c.output, "Retrying")  # check retries are happening
            @test count(r"\[ Fail Fast:", c.output) == 2
            msg = "[ Fail Fast: Test item \"bad\" at $relfpath:4 failed. Cancelling tests."
            @test contains(c.output, msg)
            if nworkers == 3
                @test contains(c.output, "[ Fail Fast: 3/3 test items were run.")
            else
                @test contains(c.output, "[ Fail Fast: 2/3 test items were run.")
            end
        end # nworkers
    end # case
    # When there are failing test items running in parallel on 2 different workers, both
    # failure should be reported, but there should only ever be one "Cancelling" message.
    @testset "multiple failures" begin
        file = joinpath(TEST_FILES_DIR, "_failfast_multiple_failure_tests.jl")
        c = IOCapture.capture() do
            encased_testset(() -> runtests(file; nworkers=2, failfast=true))
        end
        results = c.value
        @test n_tests(results) == 2
        @test n_passed(results) == 0
        @test count(r"Cancelling tests.", c.output) == 1
        @test count(r"\[ Fail Fast:", c.output) == 2
        @test contains(c.output, "[ Fail Fast: 2/3 test items were run.")
    end
    # test setting `failfast` via environment variable
    @testset "ENV var" begin
        file = joinpath(TEST_FILES_DIR, "_failfast_failure_tests.jl")
        c = withenv("RETESTITEMS_FAILFAST" => "true") do
            IOCapture.capture() do
                encased_testset(()->runtests(file))
            end
        end
        results = c.value
        @test n_tests(results) == 2
        @test n_passed(results) == 1
        @test contains(c.output, "[ Fail Fast: 2/3 test items were run.")
    end
end

# In Julia v1.9, `@testset` supports its own `failfast` keyword
# See https://github.com/JuliaLang/julia/commit/88def1afe16acdfe41b15dc956742359d837ce04
# Test that we are not rethrowing a `Test.FailFastError`.
if VERSION >= v"1.9"
    @testset "Handle `@testset failfast=true`" begin
        file = joinpath(TEST_FILES_DIR, "_testset_failfast_tests.jl")
        results = encased_testset(()->runtests(file))
        # We should only see that a single test-item ran and had a single test failure,
        # we should not see a `Test.FailFastError` error.
        @test n_tests(results) == 1
        @test length(non_passes(results)) == 1
        @test length(errors(results)) == 0
    end
end

# In earlier versions of ReTestItems, if the testitem threw an error (outside of an `@test`)
# we would report the time taken as `"0 secs"` in the DONE log message, because we didn't
# have any timing info in `@timed_wth_compilation`. Now we should fallback to the timing
# info in the testset, which for this tests should be non-zero.
@testset "DONE time reported when testitem throws" begin
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_error_test.jl")
    c = IOCapture.capture() do
        encased_testset(()->runtests(file))
    end
    expected = r"DONE  \(1/1\) test item \"Test that throws outside of a @test\" (\d.\d) secs"
    m = match(expected, c.output)
    @test m != nothing
    @test parse(Float64, only(m)) > 0
end

# `testitem_failfast` only support in Julia v1.9+ because it relies on the
# `Test.DefaultTestSet` having `failfast`, which was added in v1.9.
@testset "runtests `testitem_failfast` keyword" begin
if VERSION < v"1.9.0-"
    @test_skip :testitem_failfast
else
    using IOCapture
    file = joinpath(TEST_FILES_DIR, "_testitem_failfast_tests.jl")
    c = IOCapture.capture() do
        encased_testset(()->runtests(file; testitem_failfast=true))
    end
    d1 = r"DONE  \(1/2\) test item \"Failure at toplevel\" \d.\d secs \(Failed Fast\)"
    d2 = r"DONE  \(2/2\) test item \"Failure in nested testset\" \d.\d secs \(Failed Fast\)"
    @test contains(c.output, d1)
    @test contains(c.output, d2)
    results = c.value
    # 1st testitem should have a test failure, then not run the other tests
    # 2nd testitem should have a test pass then a test failure, then not run the other tests
    @test n_tests(results) == 3
    @test n_passed(results) == 1
    @test length(failures(results)) == 2

    # Same tests, but this time each `@testitem` set `failfast=true`
    file = joinpath(TEST_FILES_DIR, "_testitem_failfast_set_tests.jl")
    c = IOCapture.capture() do
        # `@testitem failfast=true` takes precedence over `testitem_failfast=false`
        encased_testset(()->runtests(file; testitem_failfast=false))
    end
    d1 = r"DONE  \(1/2\) test item \"Failure at toplevel\" \d.\d secs \(Failed Fast\)"
    d2 = r"DONE  \(2/2\) test item \"Failure in nested testset\" \d.\d secs \(Failed Fast\)"
    @test contains(c.output, d1)
    @test contains(c.output, d2)
    results = c.value
    # 1st testitem should have a test failure, then not run the other tests
    # 2nd testitem should have a test pass then a test failure, then not run the other tests
    @test n_tests(results) == 3
    @test n_passed(results) == 1
    @test length(failures(results)) == 2
    @testset "ENV var" begin
        file = joinpath(TEST_FILES_DIR, "_testitem_failfast_tests.jl")
        results = withenv("RETESTITEMS_TESTITEM_FAILFAST" => "true") do
            encased_testset(()->runtests(file))
        end
        @test n_tests(results) == 3
        @test n_passed(results) == 1
        @test length(failures(results)) == 2
    end
    @testset "`testitem_failfast` defaults to `failfast`" begin
        # Passing `failfast=true` should also set `testitem_failfast=true`
        file = joinpath(TEST_FILES_DIR, "_testitem_failfast_tests.jl")
        c = IOCapture.capture() do
            encased_testset(()->runtests(file; failfast=true))
        end
        d1 = r"DONE  \(1/2\) test item \"Failure at toplevel\" \d.\d secs \(Failed Fast\)"
        d2 = r"DONE  \(2/2\)"
        @test contains(c.output, d1)
        @test !contains(c.output, d2)
        @test contains(c.output, "[ Fail Fast: 1/2 test items were run.")
        results = c.value
        # 1st testitem should have a test failure, then not run the other tests
        # 2nd testitem should not run
        @test n_tests(results) == 1
        @test n_passed(results) == 0
        @test length(failures(results)) == 1
    end
    @testset "`testitem_failfast` can be disabled when `failfast=true`" begin
        file = joinpath(TEST_FILES_DIR, "_testitem_failfast_tests.jl")
        c = IOCapture.capture() do
            withenv("RETESTITEMS_TESTITEM_FAILFAST" => "false") do
                encased_testset(()->runtests(file; failfast=true))
            end
        end
        d1 = r"DONE  \(1/2\) test item \"Failure at toplevel\" \d.\d secs"
        d2 = r"DONE  \(2/2\)"
        @test contains(c.output, d1)
        @test !contains(c.output, d2)
        @test !contains(c.output, "(Failed Fast)")
        @test contains(c.output, "[ Fail Fast: 1/2 test items were run.")
        results = c.value
        # 1st testitem should have a failure, a error, another failure, then a pass
        # 2nd testitem should not run
        @test n_tests(results) == 4
        @test n_passed(results) == 1
        @test length(failures(results)) == 2
        @test length(errors(results)) == 1
    end
end # VERSION
end

@testset "`test_end_expr` must be `:block`" begin
    @test_throws "`test_end_expr` must be a `:block` expression" runtests(; test_end_expr=:(@assert false))
end

@testset "warn if no test items" begin
    using ReTestItems: NoTestException
    exc = NoTestException("No test items found.")
    @test_throws exc runtests(joinpath(TEST_FILES_DIR, "_empty_file_test.jl"))
    @test_throws exc runtests(joinpath(TEST_FILES_DIR, "_empty_file_test.jl"); nworkers=1)
    @test_throws exc runtests(joinpath(TEST_FILES_DIR, "_happy_tests.jl"); name="blahahahaha_nope")
    @test_throws exc runtests(joinpath(TEST_FILES_DIR, "_happy_tests.jl"); tags=[:blahahahaha_nope])
end

end # integrationtests.jl testset
