using ReTestItems

@testitem "NoDeps" begin
    using NoDeps
    @test answer() == 42
    println("NoDeps tests done!")
end

runtests(verbose=1)
