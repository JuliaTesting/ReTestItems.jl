using ReTestItems
# using NoDeps  # TODO: uncomment when TestEnv

@testitem "NoDeps" begin

    # TODO: remove this hack once we correctly `TestEnv.activate` the right environment.
    # Also this hack breaks Pkg.test()
    @eval begin
        using Pkg
        Pkg.activate(temp=true)
        Pkg.develop(path=dirname(@__DIR__))
    end
    using NoDeps

    @test answer() == 42
    println("NoDeps tests done!")
end

runtests(@__DIR__)
# runtests(NoDeps)  # TODO: uncomment when TestEnv
