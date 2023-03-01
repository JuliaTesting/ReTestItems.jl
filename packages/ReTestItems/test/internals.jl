# Unit tests for internal helper functions

@testset "walkdir" begin
    using ReTestItems: ReTestItems, walkdir

    # single directory arg is same as Base.walkdir
    @test collect(walkdir(@__DIR__)) == collect(Base.walkdir(@__DIR__))
    @test collect(walkdir("")) == collect(Base.walkdir(""))

    # For tests below, retrieve the flat list of files in order to make comparison easier
    _flatten(x) = mapreduce(_flatten, vcat, x; init=[])
    _flatten((root, dirs, files)::Tuple) = map(file -> joinpath(root, file), files)

    # walkdir can accept filenames (not just directories, unlike Base.walkdir)
    dir = pkgdir(ReTestItems)
    file = "$dir/test/internals.jl"
    @assert isfile(file)
    @test _flatten(walkdir(file)) == [file]
end

@testset "istestfile" begin
    using ReTestItems: istestfile
    @test !istestfile("test/runtests.jl")
    @test !istestfile("test/bar.jl")

    @test !istestfile("test/runtests.csv")
    @test !istestfile("test/bar/qux.jlx")

    @test istestfile("foo_test.jl")
    @test istestfile("foo_tests.jl")

    @test !istestfile("foo.jl")

    @test istestfile("src/foo_test.jl")
    @test istestfile("./src/foo_test.jl")
    @test istestfile("../src/foo_test.jl")
    @test istestfile(abspath("../src/foo_test.jl"))
    @test istestfile("path/to/my/package/src/foo_test.jl")

    @test !istestfile("src/foo.jl")
    @test !istestfile("./src/foo.jl")
    @test !istestfile("../src/foo.jl")
    @test !istestfile(abspath("../src/foo.jl"))
    @test !istestfile("path/to/my/package/src/foo.jl")
end

@testset "Warn when no testfiles matched" begin
    using ReTestItems: FilteredChannel, include_testfiles!, identify_project
    c = FilteredChannel(Returns(true), Channel(Inf))

    @test_logs (:warn, r"/this/file/is/not/a/t-e-s-tfile.jl") begin
        include_testfiles!(c, "/this/file/", ("/this/file/is/not/a/t-e-s-tfile.jl",))
    end
    @assert Base.n_avail(c.ch) == 0

    @test_logs (:warn, r"/this/file/does/not/exist/imaginary_tests.jl") begin
        include_testfiles!(c, "/this/file/", ("/this/file/does/not/exist/imaginary_tests.jl",))
    end
    @assert Base.n_avail(c.ch) == 0

    @test_logs (:warn, r"/this/dir/does/not/exist/") begin
        include_testfiles!(c, "/this/dir/", ("/this/dir/does/not/exist/",))
    end
    @assert Base.n_avail(c.ch) == 0

    @test_logs (:warn, r"/this/dir/does/not/exist/") (:warn, r"/this/dir/also/does/not/exist/") begin
        include_testfiles!(c, "/this/dir/", ("/this/dir/does/not/exist/", "/this/dir/also/does/not/exist/",))
    end
    @assert Base.n_avail(c.ch) == 0

    @test_logs (:warn, r"/this/dir/does/not/exist/") (:warn, r"/this/dir/has/imaginary_tests.jl") begin
        include_testfiles!(c, "/this/dir/", ("/this/dir/does/not/exist/", "/this/dir/has/imaginary_tests.jl",))
    end
    @assert Base.n_avail(c.ch) == 0

    pkg = joinpath(pkgdir(ReTestItems), "test", "packages", "TestsInSrc.jl")
    project = identify_project(pkg)

    @test_nowarn include_testfiles!(c, project, (pkg,))
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)

    @test_logs (:warn, Regex(joinpath(pkg, "test"))) begin
        include_testfiles!(c, project, (joinpath(pkg, "test"), joinpath(pkg, "src"),))
    end
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)

    @test_logs (:warn, Regex(joinpath(pkg, "doesntexist"))) begin
        include_testfiles!(c, project, (joinpath(pkg, "src"), joinpath(pkg, "doesntexist"),))
    end
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)

    @test_logs (:warn, Regex(joinpath(pkg, "src", "foo.jl"))) begin
        include_testfiles!(c, project, (joinpath(pkg, "src", "foo.jl"),  joinpath(pkg, "src", "foo_test.jl"),))
    end
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)

    @test_logs (:warn, Regex(joinpath(pkg, "test"))) begin
        include_testfiles!(c, project, (joinpath(pkg, "src", "foo_test.jl"),  joinpath(pkg, "test"),))
    end
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)

    @test_nowarn include_testfiles!(c, project, (joinpath(pkg, "src", "foo_test.jl"),))
    @assert Base.n_avail(c.ch) > 0
    empty!(c.ch.data)
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
    ti = TestItem("Dummy TestItem", [], false, [], "source/path", 42, ".", nothing, [], IOBuffer(), Ref{Int}())

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
