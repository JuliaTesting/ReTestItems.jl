# this file specifically tests *unit* tests for ReTestItems
# so *not* the `runtests` functionality, which utilizes specific
# contrived packages/testfiles
ReTestItems.reset_global_test_context!()

@testset "testsetup macro basic" begin
    @testsetup module TS1
        x = 1
    end
    @test ReTestItems.get_test_setup(:TS1).name == :TS1
end

@testset "testitem macro basic" begin
    ti = @testitem "TI1" begin
        @test 1 + 1 == 2
    end
    @test ti.name == "TI1"
    @test ti.file == @__FILE__
    @test ReTestItems.runtestitem(ti) === nothing
end

@testset "testitem with tags" begin
    ti2 = @testitem "TI2" tags=[:foo] begin
        @test true
    end
    @test ti2.tags == [:foo]
    @test ReTestItems.runtestitem(ti2) === nothing
end

@testset "testitem with macro import" begin
    # Test that `@testitem` correctly imports macros before expanding macros.
    ti3 = @testitem "macro-import" begin
        # Test with something that won't be imported in Main
        # i.e. not Base, Test, or TestsInSrc (i.e. this package)
        # Let's use a small package with a widely-used macro.
        # We merely want to check that this testitem runs without hitting
        # a `UndefVarError: @auto_hash_equals not defined`.
        using AutoHashEquals: @auto_hash_equals
        @auto_hash_equals mutable struct MacroTest
            x
        end
        @test MacroTest(1) isa MacroTest
    end
    @test ReTestItems.runtestitem(ti3) === nothing
end

@testset "testitem with setup" begin
    @testsetup module FooSetup
        x = 1
        const y = 2
        export y
    end
    # test that imported macro usage also works in testsetup
    @testsetup module FooSetup2
        using AutoHashEquals: @auto_hash_equals
        @auto_hash_equals struct Foo
            x::Int
        end
        @assert Foo(1) isa Foo
    end
    ti4 = @testitem "Foo" setup=[FooSetup, FooSetup2] begin
        @test FooSetup.x == 1
        @test y == 2
        @test FooSetup2.Foo(1) isa FooSetup2.Foo
    end
    @test ti4.setup == [:FooSetup, :FooSetup2]
    @test ReTestItems.runtestitem(ti4) === nothing
end

@testset "testsetup and testitem with includes" begin
    @testsetup module FooSetup3
        include("_testsetupinclude.jl")
    end
    ti5 = @testitem "Foo3" setup=[FooSetup3] begin
        include("_testiteminclude.jl")
    end
    @test ReTestItems.runtestitem(ti5) === nothing
end
