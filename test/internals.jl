# Unit tests for internal helper functions

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

@testset "only requested testfiles included" begin
    using ReTestItems: ReTestItems, include_testfiles!, identify_project, is_test_file
    shouldrun = Returns(true)
    report = false

    # Requesting only non-existent files/dirs should result in no files being included
    ti, setups = include_testfiles!("proj", "/this/file/", ("/this/file/is/not/a/t-e-s-tfile.jl",), shouldrun, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    ti, setups = include_testfiles!("proj", "/this/file/", ("/this/file/does/not/exist/imaginary_tests.jl",), shouldrun, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    ti, setups = include_testfiles!("proj", "/this/dir/", ("/this/dir/does/not/exist/", "/this/dir/also/not/exist/"), shouldrun, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a file that's not a test-file should result in no file being included
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src", "NoDeps.jl")
    @assert isfile(pkg_file)
    project = identify_project(pkg_file)
    ti, setups = include_testfiles!("NoDeps.jl", project, (pkg_file,), shouldrun, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a dir that has no test-files should result in no file being included
    pkg_src = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src")
    @assert all(!is_test_file, readdir(pkg_src))
    project = identify_project(pkg_src)
    ti, setups = include_testfiles!("NoDeps.jl", project, (pkg_src,), shouldrun, report)
    @test isempty(ti.testitems)
    @test isempty(setups)

    # Requesting a test-files should result in the file being included
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl", "src", "foo_test.jl")
    @assert isfile(pkg_file) && is_test_file(pkg_file)
    project = identify_project(pkg_file)
    ti, setups = include_testfiles!("TestsInSrc.jl", project, (pkg_file,), shouldrun, report)
    @test length(ti.testitems) == 1
    @test isempty(setups)

    # Requesting a dir that has test-files should result in files being included
    pkg = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl")
    @assert any(!is_test_file, readdir(joinpath(pkg, "src")))
    project = identify_project(pkg)
    ti, setups = include_testfiles!("TestsInSrc.jl", project, (pkg,), shouldrun, report)
    @test map(x -> x.name, ti.testitems) == ["a1", "a2", "z", "y", "x", "b", "bar", "foo"]
    @test isempty(setups)
end

@testset "testsetup files always included" begin
    using ReTestItems: include_testfiles!, is_test_file, is_testsetup_file
    shouldrun = Returns(true)
    report = false
    proj = joinpath(pkgdir(ReTestItems), "Project.toml")
    test_dir = joinpath(pkgdir(ReTestItems), "test")
    @assert count(is_testsetup_file, readdir(test_dir)) == 1
    file = joinpath(test_dir, "log_capture.jl")
    @assert isfile(file) && !is_test_file(file)
    ti, setups = include_testfiles!("log_capture", proj, (file,), shouldrun, report)
    @test length(ti.testitems) == 0 # just the testsetup
    @test haskey(setups, :FooSetup)

    # even when higher up in directory tree
    nested_dir = joinpath(pkgdir(ReTestItems), "test", "_nested")
    @assert !any(is_testsetup_file, readdir(nested_dir))
    file = joinpath(nested_dir, "_testitem_test.jl")
    @assert isfile(file)
    ti, setups = include_testfiles!("_nested", proj, (file,), shouldrun, report)
    @test length(ti.testitems) == 1 # the testsetup and only one test item
    @test haskey(setups, :FooSetup)
end

@testset "Warn on empty test set" begin
    using ReTestItems: TestItem, report_empty_testsets, PerfStats, ScheduledForEvaluation
    using Test: DefaultTestSet, Fail, Error
    ti = TestItem(Ref(42), "Dummy TestItem", [], false, [], 0, "source/path", 42, ".", nothing, [], Ref{Int}(), Test.DefaultTestSet[], Ref{Int}(0), PerfStats[], ScheduledForEvaluation())

    ts = DefaultTestSet("Empty testset")
    report_empty_testsets(ti, ts)
    @test_logs (:warn, r"\"Empty testset\"") report_empty_testsets(ti, ts)

    ts = DefaultTestSet("Testset containing an empty testset")
    push!(ts.results, DefaultTestSet("Empty testset"))
    # Only the inner testset is considered empty
    @test_logs (:warn, """
        Test item "Dummy TestItem" at source/path:42 contains test sets without tests:
        "Empty testset"
        """) begin
        report_empty_testsets(ti, ts)
    end

    ts = DefaultTestSet("Testset containing empty testsets")
    push!(ts.results, DefaultTestSet("Empty testset 1"))
    push!(ts.results, DefaultTestSet("Empty testset 2"))
    # Only the inner testsets are considered empty
    @test_logs (:warn, """
        Test item "Dummy TestItem" at source/path:42 contains test sets without tests:
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
