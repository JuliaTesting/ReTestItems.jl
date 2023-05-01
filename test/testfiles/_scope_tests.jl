# `@testitem` should have local (soft) scope (just like the REPL), and
# not global scope (like a `module`).
# This test would fail with `UndefVarError: x not defined` if `@testitem` had global scope.
@testitem "scope test - loops" begin
    x = 0
    for i = 1:3
       x += 1
    end
    @test x == 3
end

# Test that `@testsetup` are available as expected.
@testsetup module ScopeSetup
    foo = 10
    bar = 1
    export bar
end
@testitem "scope test - setups" setup=[ScopeSetup] begin
    x = 0
    for i = 1:3
       x += ScopeSetup.foo + bar
    end
    @test x == 33
end

# Test `@testset`s inherit the expected scope
@testitem "scope test - testsets" begin
    x = 0
    for i = 1:3
       x += 1
    end
    @testset "nested test" begin
        @test x == 3
    end
end

# Test imports work as expected, so long as they're at the "top level" of the testitem.
@testitem "scope test - imports" begin
    using AutoHashEquals: @auto_hash_equals
    @testset "use import" begin
        @auto_hash_equals struct Foo
            x::Int
        end
        foo1 = Foo(42)
        foo2 = Foo(42)
        @test foo1 == foo2
    end
    # make sure we still have the expected scoping rules at the top level
    x = 0
    for i = 1:3
       x += 1
    end
    @test x == 3
end

# Test `const` statements work, so long as they're at the "top level" of the testitem.
@testitem "scope test - consts" begin
    const x = 1
    @testset "nested test" begin
        @test x == 1
    end
end
