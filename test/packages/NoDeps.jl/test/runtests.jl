using ReTestItems
using NoDeps

@testitem "NoDeps" begin
    using NoDeps
    @test answer() == 42
    println("NoDeps tests done!")
end

runtests(NoDeps, verbose=1)
