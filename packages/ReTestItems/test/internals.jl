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

@testset "only requested testfiles included" begin
    using ReTestItems: FilteredChannel, include_testfiles!, identify_project, is_test_file
    c = FilteredChannel(Returns(true), Channel(Inf))

    # Requesting only non-existent files/dirs should result in no files being included
    include_testfiles!(c, "/this/file/", ("/this/file/is/not/a/t-e-s-tfile.jl",))
    @test Base.n_avail(c.ch) == 0

    include_testfiles!(c, "/this/file/", ("/this/file/does/not/exist/imaginary_tests.jl",))
    @test Base.n_avail(c.ch) == 0

    include_testfiles!(c, "/this/dir/", ("/this/dir/does/not/exist/", "/this/dir/also/not/exist/"))
    @test Base.n_avail(c.ch) == 0

    # Requesting a file that's not a test-file should result in no file being included
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src", "NoDeps.jl")
    @assert isfile(pkg_file)
    project = identify_project(pkg_file)
    include_testfiles!(c, project, (pkg_file,))
    @test Base.n_avail(c.ch) == 0

    # Requesting a dir that has no test-files should result in no file being included
    pkg_src = joinpath(pkgdir(ReTestItems), "test", "packages", "NoDeps.jl", "src")
    @assert all(!is_test_file, readdir(pkg_src))
    project = identify_project(pkg_src)
    include_testfiles!(c, project, (pkg_src,))
    @test Base.n_avail(c.ch) == 0

    # Requesting a test-files should result in the file being included
    c = FilteredChannel(Returns(true), Channel(Inf))
    pkg_file = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl", "src", "foo_test.jl")
    @assert isfile(pkg_file) && is_test_file(pkg_file)
    project = identify_project(pkg_file)
    include_testfiles!(c, project, (pkg_file,))
    @test Base.n_avail(c.ch) == 1

    # Requesting a dir that has test-files should result in files being included
    c = FilteredChannel(Returns(true), Channel(Inf))
    pkg = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl")
    @assert any(!is_test_file, readdir(joinpath(pkg, "src")))
    project = identify_project(pkg)
    include_testfiles!(c, project, (pkg,))
    @test Base.n_avail(c.ch) > 0
end

@testset "testsetup files always included" begin
    using ReTestItems: FilteredChannel, include_testfiles!, is_test_file, is_testsetup_file
    test_dir = joinpath(pkgdir(ReTestItems), "test")
    @assert count(is_testsetup_file, readdir(test_dir)) == 1
    file = joinpath(test_dir, "log_capture.jl")
    @assert isfile(file) && !is_test_file(file)
    c = FilteredChannel(Returns(true), Channel(Inf))
    include_testfiles!(c, test_dir, (file,))
    @test Base.n_avail(c.ch) == 1  # just the testsetup

    # even when higher up in directory tree
    nested_dir = joinpath(pkgdir(ReTestItems), "test", "_nested")
    @assert !any(is_testsetup_file, readdir(nested_dir))
    file = joinpath(nested_dir, "_testitem_test.jl")
    @assert isfile(file)
    c = FilteredChannel(Returns(true), Channel(Inf))
    include_testfiles!(c, test_dir, (file,))
    @test Base.n_avail(c.ch) == 2  # the requested test file and the testsetup in dir above
end

@testset "TestSetTree" begin
    using ReTestItems: TestSetTree
    using DataStructures: dequeue!
    using Test: DefaultTestSet
    files_to_depth = Dict(
        "dir1/file1.jl" => 2,
        "dir1/dir2/file2.jl" => 3,
        "dir1/dir2/file3.jl" => 3,
        "dir1/dir2/dir3/file4.jl" => 4,
        "dir1/dir2b/file5.jl" => 3,
    )
    files_to_testsets = Dict(file => DefaultTestSet(file) for file in keys(files_to_depth))
    tree = TestSetTree()
    for (file, ts) in files_to_testsets
        get!(tree, file, ts)
    end
    @test tree.queue == files_to_depth
    @test tree.testsets == files_to_testsets
    deepest_file = "dir1/dir2/dir3/file4.jl"
    @test haskey(tree.testsets, deepest_file)
    @test dequeue!(tree) == files_to_testsets[deepest_file]
    @test !haskey(tree.testsets, deepest_file)
    # also test `get!(func, ...) method
    get!(tree, deepest_file) do
        files_to_testsets[deepest_file]
    end
    @test haskey(tree.testsets, deepest_file)
    @test dequeue!(tree) == files_to_testsets[deepest_file]
end

@testset "Warn on empty test set" begin
    using ReTestItems: TestItem, report_empty_testsets
    using Test: DefaultTestSet, Fail, Error
    ti = TestItem(42, "Dummy TestItem", [], false, [], "source/path", 42, ".", nothing, [], Ref{Int}())

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
