using NoDeps, ReTestItems

@testitem "NoDeps" begin
    using NoDeps
    @test answer() == 42
    print("NoDeps tests done!")
end

runtests(NoDeps)
