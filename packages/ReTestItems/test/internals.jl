# Unit tests for internal helper functions

@testset "walkdir" begin
    using ReTestItems: ReTestItems, walkdir

    # single directory arg is same as Base.walkdir
    @test collect(walkdir(@__DIR__)) == collect(Base.walkdir(@__DIR__))
    @test collect(walkdir("")) == collect(Base.walkdir(""))

    # For tests below, retrieve the flat list of files in order to make comparison easier
    _flatten(x) = mapreduce(_flatten, vcat, x; init=[])
    _flatten((root, dirs, files)::Tuple) = map(file -> joinpath(root, file), files)

    # walkdir with multiple directory args find same files as combined Base.walkdir calls
    dir = pkgdir(ReTestItems)
    @test !isempty(_flatten(walkdir("$dir/src", "$dir/test")))
    @test ==(
        _flatten(walkdir("$dir/src", "$dir/test")),
        vcat(_flatten(Base.walkdir("$dir/src")), _flatten(Base.walkdir("$dir/test")))
    )

    # walkdir can accept filenames (not just directories, unlike Base.walkdir)
    file = "$dir/test/internals.jl"
    @assert isfile(file)
    @test _flatten(walkdir(file)) == [file]

    # walkdir can accept mix of directory and file names
    @test ==(
        _flatten(walkdir("$dir/src", file)),
        vcat(_flatten(Base.walkdir("$dir/src")), [file])
    )
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
