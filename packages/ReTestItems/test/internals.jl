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
