# This file _does_ have a `@testitem` but also has an error (undefined variable), so
# `runtests` should throw

@testitem "pass" begin
    @test true
end

x + 2
