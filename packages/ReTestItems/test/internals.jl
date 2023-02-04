# Unit tests for internal helper functions

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
