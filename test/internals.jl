# Unit tests for internal helper functions (i.e. not public API)
using Test
using ReTestItems

@testset "internals.jl" verbose=true begin

@testset "get_starting_testitems" begin
    using ReTestItems: get_starting_testitems, TestItems, @testitem
    graph = ReTestItems.FileNode("")  # we don't use the graph info for this test
    # we previously saw `BoundsError` with 8 testitems, 5 workers.
    # let's test this exhaustively for 1-10 testitems across 1-10 workers.
    for nworkers in 1:10
        for nitems in 1:10
            testitems = [@testitem("ti-$i", _run=false, begin end) for i in 1:nitems]
            starts = get_starting_testitems(TestItems(graph, testitems), nworkers)
            startitems = [x for x in starts if !isnothing(x)]
            @test length(starts) == nworkers
            @test length(startitems) == min(nworkers, nitems)
            @test allunique(ti.name for ti in startitems)
        end
    end
end

@testset "is_test_file" begin
    using ReTestItems: is_test_file
    @test !is_test_file("test/runtests.jl")
    @test !is_test_file("test/bar.jl")

    @test !is_test_file("test/runtests.csv")
    @test !is_test_file("test/bar/qux.jlx")

    @test is_test_file("foo_test.jl")
    @test is_test_file("foo_tests.jl")
    @test is_test_file("foo-test.jl")
    @test is_test_file("foo-tests.jl")

    @test !is_test_file("foo.jl")

    @test is_test_file("src/foo_test.jl")
    @test is_test_file("./src/foo_test.jl")
    @test is_test_file("../src/foo_test.jl")
    @test is_test_file(abspath("../src/foo_test.jl"))
    @test is_test_file("path/to/my/package/src/foo_test.jl")
    @test is_test_file("path/to/my/package/src/foo-test.jl")

    @test !is_test_file("src/foo.jl")
    @test !is_test_file("./src/foo.jl")
    @test !is_test_file("../src/foo.jl")
    @test !is_test_file(abspath("../src/foo.jl"))
    @test !is_test_file("path/to/my/package/src/foo.jl")
end

@testset "is_testsetup_file" begin
    using ReTestItems: is_testsetup_file
    @test is_testsetup_file("bar_testsetup.jl")
    @test is_testsetup_file("bar_testsetups.jl")
    @test is_testsetup_file("bar-testsetup.jl")
    @test is_testsetup_file("bar-testsetups.jl")
    @test is_testsetup_file("path/to/my/package/src/bar-testsetup.jl")
end

@testset "_is_subproject" begin
    using ReTestItems: _is_subproject
    test_pkg_dir = joinpath(pkgdir(ReTestItems), "test", "packages")
    # Test subpackages in MonoRepo identified as subprojects
    monorepo = joinpath(test_pkg_dir, "MonoRepo.jl")
    monorepo_proj = joinpath(monorepo, "Project.toml")
    @assert isfile(monorepo_proj)
    for pkg in ("B", "C", "D")
        path = joinpath(monorepo, "monorepo_packages", pkg)
        @test _is_subproject(path, monorepo_proj)
    end
    for dir in ("src", "test")
        path = joinpath(monorepo, dir)
        @test !_is_subproject(path, monorepo_proj)
    end
    # Test "test/Project.toml" does cause "test/" to be subproject
    tpf = joinpath(test_pkg_dir, "TestProjectFile.jl")
    tpf_proj = joinpath(tpf, "Project.toml")
    @assert isfile(tpf_proj)
    @assert isfile(joinpath(tpf, "test", "Project.toml"))
    for dir in ("src", "test")
        path = joinpath(tpf, dir)
        @test !_is_subproject(path, tpf_proj)
    end
end

@testset "include_testfiles!" begin

@testset "only requested testfiles included" begin
    using ReTestItems: ReTestItems, include_testfiles!, identify_project, is_test_file, TestItemFilter
    shouldrun = TestItemFilter(Returns(true), nothing, nothing)
    verbose_results = false
    report = false

    # Requesting only non-existent files/dirs should result in no files being included
    ti, setups = include_testfiles!("proj", "/this/file/", ("/this/file/is/not/a/t-e-s-tfile.jl",), shouldrun, verbose_results, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    ti, setups = include_testfiles!("proj", "/this/file/", ("/this/file/does/not/exist/imaginary_tests.jl",), shouldrun, verbose_results, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    ti, setups = include_testfiles!("proj", "/this/dir/", ("/this/dir/does/not/exist/", "/this/dir/also/not/exist/"), shouldrun, verbose_results, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a file that's not a test-file should result in no file being included
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src", "NoDeps.jl")
    @assert isfile(pkg_file)
    project = identify_project(pkg_file)
    ti, setups = include_testfiles!("NoDeps.jl", project, (pkg_file,), shouldrun, verbose_results, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a dir that has no test-files should result in no file being included
    pkg_src = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src")
    @assert all(!is_test_file, readdir(pkg_src))
    project = identify_project(pkg_src)
    ti, setups = include_testfiles!("NoDeps.jl", project, (pkg_src,), shouldrun, verbose_results, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a test-files should result in the file being included
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl", "src", "foo_test.jl")
    @assert isfile(pkg_file) && is_test_file(pkg_file)
    project = identify_project(pkg_file)
    ti, setups = include_testfiles!("TestsInSrc.jl", project, (pkg_file,), shouldrun, verbose_results, report)
    @test length(ti.testitems) == 1
    @test isempty(setups)

    # Requesting a dir that has test-files should result in files being included
    pkg = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl")
    @assert any(!is_test_file, readdir(joinpath(pkg, "src")))
    project = identify_project(pkg)
    ti, setups = include_testfiles!("TestsInSrc.jl", project, (pkg,), shouldrun, verbose_results, report)
    @test map(x -> x.name, ti.testitems) == ["a1", "a2", "z", "y", "x", "b", "bar", "foo"]
    @test isempty(setups)
end

@testset "testsetup files always included" begin
    using ReTestItems: include_testfiles!, is_test_file, is_testsetup_file, TestItemFilter
    shouldrun = TestItemFilter(Returns(true), nothing, nothing)
    verbose_results = false
    report = false
    proj = joinpath(pkgdir(ReTestItems), "Project.toml")

    test_dir = joinpath(pkgdir(ReTestItems), "test", "testfiles")
    @assert count(is_testsetup_file, readdir(test_dir)) == 1
    file = joinpath(test_dir, "_empty_file.jl")
    @assert isfile(file) && !is_test_file(file)
    ti, setups = include_testfiles!("empty_file", proj, (file,), shouldrun, verbose_results, report)
    @test length(ti.testitems) == 0 # just the testsetup
    @test haskey(setups, :FooSetup)

    # even when higher up in directory tree
    nested_dir = joinpath(pkgdir(ReTestItems), "test", "testfiles", "_nested")
    @assert !any(is_testsetup_file, readdir(nested_dir))
    file = joinpath(nested_dir, "_testitem_test.jl")
    @assert isfile(file)
    ti, setups = include_testfiles!("_nested", proj, (file,), shouldrun, verbose_results, report)
    @test length(ti.testitems) == 1 # the testsetup and only one test item
    @test haskey(setups, :FooSetup)
end

end # `include_testfiles!` testset

@testset "report_empty_testsets" begin
    using ReTestItems: TestItem, report_empty_testsets, PerfStats, ScheduledForEvaluation
    using Test: DefaultTestSet, Fail, Error
    path = joinpath("source", "path")
    ti = TestItem(Ref(42), "Dummy TestItem", "DummyID", [], false, [], 0, nothing, false, nothing, path, 42, ".", nothing)

    ts = DefaultTestSet("Empty testset")
    report_empty_testsets(ti, ts)
    @test_logs (:warn, r"\"Empty testset\"") report_empty_testsets(ti, ts)

    ts = DefaultTestSet("Testset containing an empty testset")
    push!(ts.results, DefaultTestSet("Empty testset"))
    # Only the inner testset is considered empty
    @test_logs (:warn, """
        Test item "Dummy TestItem" at $(path):42 contains test sets without tests:
        "Empty testset"
        """) begin
        report_empty_testsets(ti, ts)
    end

    ts = DefaultTestSet("Testset containing empty testsets")
    push!(ts.results, DefaultTestSet("Empty testset 1"))
    push!(ts.results, DefaultTestSet("Empty testset 2"))
    # Only the inner testsets are considered empty
    @test_logs (:warn, """
        Test item "Dummy TestItem" at $(path):42 contains test sets without tests:
        "Empty testset 1"
        "Empty testset 2"
        """) begin
        report_empty_testsets(ti, ts)
    end

    ts = DefaultTestSet("Testset containing a passing test")
    ts.n_passed = 1
    @test_nowarn report_empty_testsets(ti, ts)

    ts = DefaultTestSet("Testset containing a failed test")
    push!(ts.results, Fail(:test, "false", nothing, false, LineNumberNode(43)));
    @test_nowarn report_empty_testsets(ti, ts)

    ts = DefaultTestSet("Testset that errored")
    push!(ts.results, Error(:test_nonbool, "\"False\"", nothing, nothing, LineNumberNode(43)));
    @test_nowarn report_empty_testsets(ti, ts)
end

@testset "JUnit _error_message" begin
    # Test we cope with the Error/Fail not having file info
    using ReTestItems: _error_message
    line_info = LineNumberNode(42, nothing)
    ti = (; project_root=pkgdir(ReTestItems))  # Don't need a full testitem here
    err = Test.Error(:nontest_error, Expr(:tuple), ErrorException(""), Base.ExceptionStack([]), line_info)
    @test _error_message(err, ti) == "Error during test at unknown:42"
    fail = Test.Fail(:test, Expr(:tuple), "data", "value", line_info)
    @test _error_message(fail, ti) == "Test failed at unknown:42"
end

@testset "_validated_nworker_threads" begin
    auto_cpus = string(Base.Sys.CPU_THREADS)

    @test ReTestItems._validated_nworker_threads(1) == "1"
    @test_throws ArgumentError ReTestItems._validated_nworker_threads(0)
    @test_throws ArgumentError ReTestItems._validated_nworker_threads(-1)

    @test ReTestItems._validated_nworker_threads("1") == "1"
    @test ReTestItems._validated_nworker_threads("auto") == auto_cpus
    @test_throws ArgumentError ReTestItems._validated_nworker_threads("0")
    @test_throws ArgumentError ReTestItems._validated_nworker_threads("-1")
    @test_throws ArgumentError ReTestItems._validated_nworker_threads("1auto")
    @test_throws ArgumentError ReTestItems._validated_nworker_threads("1,")

    if isdefined(Base.Threads, :nthreadpools)
        @test ReTestItems._validated_nworker_threads("1,1") == "1,1"
        @test ReTestItems._validated_nworker_threads("2,1") == "2,1"
        @test ReTestItems._validated_nworker_threads("1,2") == "1,2"
        @test ReTestItems._validated_nworker_threads("auto,1") == "$auto_cpus,1"
        @test ReTestItems._validated_nworker_threads("1,auto") == "1,1"
        @test ReTestItems._validated_nworker_threads("auto,auto") == "$auto_cpus,1"
        @test_throws ArgumentError ReTestItems._validated_nworker_threads("1,-1")
        @test_throws ArgumentError ReTestItems._validated_nworker_threads("0,0")
        @test_throws ArgumentError ReTestItems._validated_nworker_threads("0,1")
        @test_throws ArgumentError ReTestItems._validated_nworker_threads("0,auto")
    end
end

@testset "_validated_paths" begin
    _validated_paths = ReTestItems._validated_paths
    testfiles_dir = joinpath(pkgdir(ReTestItems), "test", "testfiles")

    test_file = joinpath(testfiles_dir, "_happy_tests.jl")
    @assert isfile(test_file)
    for _throw in (false, true)
        @test _validated_paths((test_file,), _throw) == (test_file,)
        @test_logs _validated_paths((test_file,), _throw) # test nothing is logged
    end

    @assert !ispath("foo")
    @test _validated_paths(("foo",), false) == ()
    @test_logs (:warn, "No such path \"foo\"") _validated_paths(("foo",), false)
    @test_throws ReTestItems.NoTestException("No such path \"foo\"") _validated_paths(("foo",), true)

    @assert isfile(test_file)
    @assert !ispath("foo")
    paths = (test_file, "foo",)
    @test _validated_paths(paths, false) == (test_file,)
    @test_logs (:warn, "No such path \"foo\"") _validated_paths(paths, false)
    @test_throws ReTestItems.NoTestException("No such path \"foo\"") _validated_paths(paths, true)

    nontest_file = joinpath(testfiles_dir, "_empty_file.jl")
    @assert isfile(nontest_file)
    @assert !ReTestItems.is_test_file(nontest_file)
    @assert !ReTestItems.is_testsetup_file(nontest_file)
    @test _validated_paths((nontest_file,), false) == ()
    @test_logs (:warn, "$(repr(nontest_file)) is not a test file") _validated_paths((nontest_file,), false)
    @test_throws ReTestItems.NoTestException("$(repr(nontest_file)) is not a test file") _validated_paths((nontest_file,), true)
end

@testset "skiptestitem" begin
    # Test that `skiptestitem` unconditionally skips a testitem
    # and returns `TestItemResult` with a single "skipped" `Test.Result`
    ti = @testitem "skip" _run=false begin
        @test true
        @test false
        @test error()
    end
    ctx = ReTestItems.TestContext("test_ctx", 1)
    ti_res = ReTestItems.skiptestitem(ti, ctx)
    @test ti_res isa TestItemResult
    test_res = only(ti_res.testset.results)
    @test test_res isa Test.Result
    @test test_res isa Test.Broken
    @test test_res.test_type == :skipped
end

@testset "should_skip" begin
    should_skip = ReTestItems.should_skip

    ti = @testitem("x", skip=true, _run=false, begin end)
    @test should_skip(ti)
    ti = @testitem("x", skip=false, _run=false, begin end)
    @test !should_skip(ti)

    ti = @testitem("x", skip=:(1 == 1), _run=false, begin end)
    @test should_skip(ti)
    ti = @testitem("x", skip=:(1 != 1), _run=false, begin end)
    @test !should_skip(ti)

    ti = @testitem("x", skip=:(x = 1; x + x == 2), _run=false, begin end)
    @test should_skip(ti)
    ti = @testitem("x", skip=:(x = 1; x + x != 2), _run=false, begin end)
    @test !should_skip(ti)

    ti = @testitem("x", skip=:(x = 1; x + x), _run=false, begin end)
    @test_throws "Test item \"x\" `skip` keyword must be a `Bool`, got `skip=2`" should_skip(ti)

    ti = @testitem("x", skip=:(x = 1; x + y), _run=false, begin end)
    if v"1.11-" < VERSION < v"1.11.2"
        # Testing for a specific UndefVarError was broken in v1.11.0 and v1.11.1, see:
        # https://github.com/JuliaLang/julia/issues/54082
        @test_throws UndefVarError should_skip(ti)
    else
        @test_throws UndefVarError(:y) should_skip(ti)
    end
end

@testset "filtering.jl" begin
    @testset "filter_testitem" begin
        using ReTestItems: filter_testitem
        ti = :(@testitem "TI" tags=[:foo, :bar] begin; @test true; end)
        ts = :(@testsetup module TS; x = 1; end)
        @test filter_testitem(Returns(true),  ti) == ti
        @test filter_testitem(Returns(false), ti) == nothing
        @test filter_testitem(Returns(true),  ts) == ts
        @test filter_testitem(Returns(false), ts) == ts
    end
    @testset "try_get_name" begin
        using ReTestItems: try_get_name
        ti = :(@testitem "TI" tags=[:foo, :bar] begin; @test true; end)
        ti_wrong1 = :(@testitem tags=[:foo, :bar] begin; @test true; end)
        ti_wrong2 = :(@testitem :TI begin; @test true; end)
        @test try_get_name(ti) == "TI"
        @test try_get_name(ti_wrong1) == nothing
        @test try_get_name(ti_wrong2) == nothing
    end
    @testset "try_get_tags" begin
        using ReTestItems: try_get_tags
        ti = :(@testitem "TI" tags=[:foo, :bar] begin; @test true; end)
        ti_no_tags = :(@testitem "TI" begin; @test true; end)
        ti_bad_tags1 = :(@testitem "TI" tags="not a symbol" begin; @test true; end)
        ti_bad_tags2 = :(@testitem "TI" tags=[:x, "not a symbol"] begin; @test true; end)
        @test try_get_tags(ti) == Symbol[:foo, :bar]
        @test try_get_tags(ti_no_tags) == Symbol[]
        @test try_get_tags(ti_bad_tags1) == nothing
        @test try_get_tags(ti_bad_tags2) == nothing
    end
    @testset "is_retestitem_macrocall" begin
        using ReTestItems: is_retestitem_macrocall
        # `@testitem` and `@testsetup` always correct
        testitem = :(@testitem "TI" tags=[:foo, :bar] begin; @test true; end)
        @test is_retestitem_macrocall(testitem)
        @test is_retestitem_macrocall(testitem)
        testsetup = :(@testsetup module TS; x = 1; end)
        @test is_retestitem_macrocall(testsetup)
        @test is_retestitem_macrocall(testsetup)
        # other macros always wrong
        testset = :(@testset "TS" begin; @test true; end)
        @test !is_retestitem_macrocall(testset)
        @test !is_retestitem_macrocall(testset)
        test = :(@test true)
        @test !is_retestitem_macrocall(test)
        @test !is_retestitem_macrocall(test)
        test_other = :(@other_macro "TX" tags=[:foo, :bar] begin; @test true; end)
        @test !is_retestitem_macrocall(test_other)
        @test !is_retestitem_macrocall(test_other)
    end
end

@testset "nestedrelpath" begin
    using ReTestItems: nestedrelpath
    if !Base.Sys.iswindows()
        @assert Base.Filesystem.path_separator == "/"
        path = "test/dir/foo_test.jl"
        @test nestedrelpath(path, "test")  == relpath(path, "test")  == "dir/foo_test.jl"
        @test nestedrelpath(path, "test/") == relpath(path, "test/") == "dir/foo_test.jl"
        @test nestedrelpath(path, "test/dir")  == relpath(path, "test/dir")  == "foo_test.jl"
        @test nestedrelpath(path, "test/dir/") == relpath(path, "test/dir/") == "foo_test.jl"
        @test nestedrelpath(path, "test/dir/foo_test.jl") == relpath(path, "test/dir/foo_test.jl") == "."

        # unlike `relpath`: if `startdir` is not a prefix of `path`, the assumption is violated,
        # and `path` is just returned as-is
        @test nestedrelpath(path, "test/dir/foo_") == "test/dir/foo_test.jl"
        @test nestedrelpath(path, "test/dir/other") == "test/dir/foo_test.jl"
        @test nestedrelpath(path, "test/dir/other/bar_test.jl") == "test/dir/foo_test.jl"

        # leading '/' doesn't get ignored or stripped
        @test nestedrelpath("/a/b/c", "/a/b") == "c"
        @test nestedrelpath("/a/b/c", "a/b") == "/a/b/c"
        @test nestedrelpath("/a/b", "/a/b/c") == "/a/b"
        @test nestedrelpath("/a/b", "c") == "/a/b"
    end
end

end # internals.jl testset
