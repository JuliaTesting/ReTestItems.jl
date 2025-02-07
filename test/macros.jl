using ReTestItems
using Test

# this file specifically tests *unit* tests for the macros: `@testitem` and `@testsetup`
# so *not* the `runtests` functionality, which utilizes specific
# contrived packages/testfiles
n_passed(ts) = ts.n_passed
n_passed(ts::ReTestItems.TestItemResult) = n_passed(ts.testset)

# Mark `ReTestItems.runtests` as running, so that `@testitem`s don't run themselves.
function no_run(f)
    old = get(task_local_storage(), :__RE_TEST_RUNNING__, false)
    try
        task_local_storage()[:__RE_TEST_RUNNING__] = true
        return f()
    finally
        task_local_storage()[:__RE_TEST_RUNNING__] = old
    end
end

@testset "macros.jl" verbose=true begin

@testset "testsetup macro basic" begin
    ts = @testsetup module TS1
        x = 1
    end
    @test ts.name == :TS1
end

@testset "testitem macro basic" begin
    ti = no_run() do
        @testitem "TI1" begin
            @test 1 + 1 == 2
        end
    end
    @test ti.name == "TI1"
    @test ti.file isa String
    @test n_passed(ReTestItems.runtestitem(ti)) == 1
end

@testset "testitem with `tags`" begin
    ti2 = no_run() do
        @testitem "TI2" tags=[:foo] begin
            @test true
        end
    end
    @test ti2.tags == [:foo]
    @test n_passed(ReTestItems.runtestitem(ti2)) == 1
end

@testset "testitem with `retries`" begin
    ti = no_run() do
        @testitem "TI" retries=2 begin
            @test true
        end
    end
    @test ti.retries == 2
    @test n_passed(ReTestItems.runtestitem(ti)) == 1
end

@testset "testitem with macro import" begin
    # Test that `@testitem` correctly imports macros before expanding macros.
    ti3 = no_run() do
            @testitem "macro-import" begin
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
    end
    @test n_passed(ReTestItems.runtestitem(ti3)) == 1
end

@testset "testitem with `setup`" begin
    ts1 = @testsetup module FooSetup
        x = 1
        const y = 2
        export y
    end
    # test that imported macro usage also works in testsetup
    ts2 = @testsetup module FooSetup2
        using AutoHashEquals: @auto_hash_equals
        @auto_hash_equals struct Foo
            x::Int
        end
        @assert Foo(1) isa Foo
    end
    ti4 = no_run() do
        @testitem "Foo" setup=[FooSetup, FooSetup2] begin
            @test FooSetup.x == 1
            @test y == 2
            @test FooSetup2.Foo(1) isa FooSetup2.Foo
        end
    end
    @test ti4.setups == [:FooSetup, :FooSetup2]
    @test n_passed(ReTestItems.runtestitem(ti4)) == 3
end

@testset "testsetup and testitem with includes" begin
    ts = @testsetup module FooSetup3
        include("_testsetupinclude.jl")
    end
    ti5 = no_run() do
        @testitem "Foo3" setup=[FooSetup3] begin
            include("_testiteminclude.jl")
        end
    end
    @test n_passed(ReTestItems.runtestitem(ti5)) == 2
end

@testset "missing testsetup" begin
    ti6 = no_run() do
        @testitem "Foo4" setup=[NonExistentSetup] begin
            @test 1 + 1 == 2
        end
    end
    ts = ReTestItems.runtestitem(ti6; finish_test=false)
    @test ts.testset.results[1] isa Test.Error
end

@testset "testitem with duplicate keywords" begin
    # can only check for text of the error message in Julia v1.8+
    expected = VERSION < v"1.8" ? Exception : "duplicate keyword"
    @test_throws expected (
        @eval @testitem "Bad" tags=[:tag1] tags=[:tags2] begin
            @test true
        end
    )
end

@testset "can identity if in a `@testitem`" begin
    @testitem "testitem active" begin
        @test get(task_local_storage(), :__TESTITEM_ACTIVE__, false)
    end
    @test !get(task_local_storage(), :__TESTITEM_ACTIVE__, false)
end

@testset "testitem macro runs immediately outside `runtests`" begin
    # Should run and return `nothing`
    @test nothing == @testitem "run" begin; @test true; end
    # Double-check it runs by looking for the START/DONE messages.
    # The START/DONE messages are always logged to DEFAULT_STDOUT, so we need to catch that.
    old = ReTestItems.DEFAULT_STDOUT[]
    try
        io = IOBuffer()
        ReTestItems.DEFAULT_STDOUT[] = io
        @testitem "run" begin
            @test true
        end
        output = String(take!(io))
        @test contains(output, r"START\s*test item \"run\"")
        @test contains(output, r"DONE\s*test item \"run\"")
    finally
        ReTestItems.DEFAULT_STDOUT[] = old
    end
    @testset "`runtestitem` default behaviour" begin
        # When running an individual test-item by itself we default to verbose output
        # i.e. eager logs and full results table.
        using IOCapture
        # run `testset_func` as if not already inside a testset, so it prints results immediately.
        function toplevel_testset(testset_func)
            old = get(task_local_storage(), :__BASETESTNEXT__, nothing)
            try
                if old !== nothing
                    delete!(task_local_storage(), :__BASETESTNEXT__)
                end
                testset_func()
            finally
                if old !== nothing
                    task_local_storage()[:__BASETESTNEXT__] = old
                end
            end
        end
        c = IOCapture.capture() do
            toplevel_testset() do
                @testitem "comparisons" begin
                    @testset "min" begin
                        @info "test 1"
                        @test min(1, 2) == 1
                    end
                    @testset "max" begin
                        @info "test 2"
                        @test max(1, 2) == 2
                    end
                end
            end
        end
        @test contains(
            c.output,
            r"""
            \[ Info: test 1
            \[ Info: test 2
            Test Summary: \| Pass  Total  Time
            comparisons   \|    2      2  \d*.\ds
              min         \|    1      1  \d*.\ds
              max         \|    1      1  \d*.\ds
            """
        )
    end
end

@testset "manually specify `source` location" begin
    # this would point to the definition in runtests.jl, if we weren't correctly setting the
    # source location manually
    line = @__LINE__() + 1
    ti = @foo_test "one"
    @test ti.file == @__FILE__
    @test ti.line == line

    ti = @testitem "two" _source=LineNumberNode(42, "foo.jl") _run=false begin; end;
    @test ti.file == "foo.jl"
    @test ti.line == 42
end

@testset "testsetup not given module" begin
    # can only check for text of the error message in Julia v1.8+
    expected = VERSION < v"1.8" ? Exception : "`@testsetup` expects a `module ... end` argument"
    @test_throws expected (@eval @testsetup(FooSetup))

    expected = VERSION < v"1.8" ? Exception : "no method matching"
    @test_throws expected (@eval @testsetup("foo", begin end))
end

@testset "testitem `_id` keyword" begin
    # Should default to `repr(hash(name, hash(file)))` where `file` is relative to the root
    # of the project being tested.
    file = joinpath("test, macros.jl") # this file
    # set the source to be this file, so that the test is valid even when run in the REPL.
    ti1 = @testitem "one" _run=false _source=LineNumberNode(@__LINE__, file) begin; end;
    @test ti1.id == repr(hash("one", hash(file)))
    # Should accept an `AbstractString`.
    ti2a = @testitem "two" _id="two" _run=false begin; end;
    ti2b = @testitem "two" _id=Test.GenericString("two") _run=false begin; end;
    @test ti2a.id == "two"
    @test ti2b.id == "two"
    # Should accept an expression evaluating to a string.
    ti3 = @testitem "three" _id=repr(hash("3")) _run=false begin; end;
    @test ti3.id == repr(hash("3"))
    # Should not accept anything but a string or an expression evaluating to a string.
    # Can detect `id` is an Int at macro-expansion time, so throws hand-written error.
    expected = VERSION < v"1.8" ? LoadError : "must be passed a string"
    @test_throws expected (@eval @testitem("four", _id=1, _run=false, begin end))
    # Cannot detect type of `id` at macro-expansion time, so throws run-time error
    expected = VERSION < v"1.8" ? MethodError : "MethodError: Cannot `convert` an object of type $(UInt) to an object of type String"
    @test_throws expected (@eval @testitem("five", _id=hash("five"), _run=false, begin end))
end

# Here we are just testing how the `timeout` keyword is parsed.
# The actual timeout functionality is tested in `integrationtests.jl`,
# because we need to call `runtests` with multiple workers to test timeout functionality.
# See https://github.com/JuliaTesting/ReTestItems.jl/issues/87
@testset "testitem `timeout` keyword" begin
    expected(t) = "`timeout` keyword must be passed a positive number. Got `timeout=$t`"
    for t in (0, -1.1)
        @test_throws expected(t) (
            @eval @testitem "Bad" timeout=$t begin
                @test true
            end
        )
    end

    @test_throws "`timeout` keyword must be passed a `Real`" (
        @eval @testitem "Bad" timeout=1im begin
            @test true
        end
    )

    no_run() do
        ti = @testitem "TI" timeout=1 begin
            @test true
        end
        @test ti.timeout isa Int
        @test ti.timeout == 1

        # We round up to the nearest second.
        ti = @testitem "TI" timeout=1.1 begin
            @test true
        end
        @test ti.timeout isa Int
        @test ti.timeout == 2

        ti = @testitem "TI" begin
            @test true
        end
        @test ti.timeout == nothing
    end
end

@testset "testitem `skip` keyword" begin
    function test_skipped(ti_result)
        ts = ti_result.testset
        # No tests should have been run
        @test n_passed(ts) == 0
        # A single "skipped" result should be recorded. Test uses `Broken` for skipped.
        @test only(ts.results) isa Test.Broken
        # Since no test was run, the stats should be empty / zeroed.
        @test ti_result.stats == ReTestItems.PerfStats()
    end
    # test case `skip` is a `Bool`
    ti = @testitem "skip isa bool" skip=true _run=false begin
        @test true
    end
    @test ti.skip
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)

    # test no code in the test item is run when `skip=true`
    ti = @testitem "test contains error" skip=true _run=false begin
        @test error("err")
    end
    @test ti.skip
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)

    # test case `skip` given a literal that's not a `Bool`
    expected = "`skip` keyword must be passed a `Bool`"
    @test_throws expected (
        @eval @testitem "bad 1" skip=123 begin
            @test true
        end
    )
    @test_throws expected (
        @eval @testitem "bad 2" skip=foo begin
            @test true
        end
    )

    # test case `skip` is a `Expr` evaluating to a `Bool`
    ti = @testitem "skip isa expr 1" skip=:(1+1 == 2) _run=false begin
        @test true
    end
    # want to test a case where `skip` is not a `:block`
    @assert ti.skip.head != :block
    @test ti.skip == :(1+1 == 2)
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)

    # test case `skip` is a `Expr` evaluating to a `Bool`
    ti = @testitem "skip isa expr 2" skip=(quote 1+1 == 2 end) _run=false begin
        @test true
    end
    # want to test a case where `skip` is a `:block`
    @assert ti.skip.head == :block
    @test Base.remove_linenums!(ti.skip) == Base.remove_linenums!(quote 1+1 == 2 end)
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)

    # test that no code is evaluated until `runtestitem` is called
    ti = @testitem "skip expr has error" skip=:(throw("oops")) _run=false begin
        @test true
    end
    @test ti.skip == :(throw("oops"))
    @test_throws "oops" ReTestItems.runtestitem(ti)

    # test that skip expression can load modules
    ti = @testitem "skip expr loads module" skip=:(using AutoHashEquals; AutoHashEquals isa Module) _run=false begin
        @test true
    end
    @test ti.skip isa Expr
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)

    # test that skip expression does not pollute Main
    var = gensym(:skip_var)
    ti = @testitem "skip expr defines variable" skip=:($var=1; $var==1) _run=false begin
        @test true
    end
    @test ti.skip isa Expr
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)
    @test !isdefined(Main, var)

    # test that skip expression does not get modified
    @testitem "skip not modified" skip=(x=1; x==1) _run=false begin
        @test true
    end
    @assert ti.skip isa Expr
    before = deepcopy(ti.skip)
    @assert ti.skip !== before
    res = ReTestItems.runtestitem(ti)
    test_skipped(res)
    @test ti.skip == before

    @testset "skipping is logged" begin
        old = ReTestItems.DEFAULT_STDOUT[]
        try
            io = IOBuffer()
            ReTestItems.DEFAULT_STDOUT[] = io
            line = @__LINE__() + 1
            ti = @testitem "skip this" skip=true _run=false begin
                @test true
            end
            file = relpath(@__FILE__(), ti.project_root)
            ReTestItems.runtestitem(ti)
            output = String(take!(io))
            @test contains(output, "SKIP test item \"skip this\" at $file:$line")
        finally
            ReTestItems.DEFAULT_STDOUT[] = old
        end
    end
end

# Actual `@testitem failfast` behaviour tested in test/integrationtests.jl
@testset "tesitem `failfast` keyword" begin
    ti = @testitem "foo" failfast=true _run=false begin
        @test false
        @test true
    end
    @test ti.failfast == true
    @test_throws "`failfast` keyword must be passed a `Bool`" (
        @eval @testitem "bad 1" failfast=nothing begin
            @test true
        end
    )
end

@testset "testitem with `default_imports`" begin
    ti = @testitem "default_imports" default_imports=true _run=false begin
        @test @isdefined Test
        @test @isdefined ReTestItems
    end
    @test ti.default_imports == true
    res = ReTestItems.runtestitem(ti)
    @test n_passed(res) == 3

    ti = @testitem "no_default_imports" default_imports=false _run=false begin
        # use `@assert` since we cannot use `@test`
        @assert !(@isdefined Test)
        @assert !(@isdefined ReTestItems)
    end
    @test ti.default_imports == false
    ReTestItems.runtestitem(ti) # check `@assert` not triggered

    @test_throws "`default_imports` keyword must be passed a `Bool`" (
        @eval @testitem "Bad" default_imports=1 begin
            @test true
        end
    )
end

@testset "testitem with unrecognised keyword" begin
    @test_throws "unknown `@testitem` keyword arg `quux`" (
        @eval @testitem "Bad" quux=1 begin
            @test true
        end
    )
end

@testset "testitem without a body" begin
    @test_throws "expected `@testitem` to have a body" (@eval @testitem "wrong")
    @test_throws "expected `@testitem` to have a body" (@eval @testitem "wrong" @test 1==1)
    @test_throws "expected `@testitem` to have a body" (@eval @testitem "wrong" let @test 1==1 end)
    @test_throws "expected `@testitem` to have a body" (@eval @testitem "wrong" quote @test 1==1 end)
end


#=
NOTE:
    These tests are disabled as we stopped using anonymous modules;
    there were issues when tests tried serialize/deserialize with things defined in
    an anonymous module.

# Make these globals so that our testitem can access it via Main.was_finalized
was_finalized = Threads.Atomic{Bool}(false)
# Define the struct outside the testitem, since otherwise the Method Table prevents the
# testitem module from being GC'd. See: https://github.com/JuliaLang/julia/issues/48711
mutable struct MyTempType
    v::Int
    function MyTempType(v)
        x = new(v)
        Core.println("I made a new ", pointer_from_objref(x))
        finalizer(x) do obj
            Core.println("I am destroyed!")
            Core.println(pointer_from_objref(obj))
            Main.was_finalized[] = true
        end
        return x
    end
end

# disabled for now since there are issues w/ eval-ing
# testitems into anonymous modules
# @testset "testitems are GC'd correctly" begin
#     ti7 = @testitem "Foo7" begin
#         x = Main.MyTempType(1)
#         x = nothing
#         GC.gc()
#         GC.gc()
#         @test Main.was_finalized[] = true

#         # Now reset this, and keep a "global" object around
#         Main.was_finalized[] = false
#         x2 = Main.MyTempType(1)
#         @test x2.v == 1

#         # Then return. After running GC.gc() _outside_ the testitem, we should
#         # free the entire testitem, including the global objects its holding onto,
#         # including `x2`, which should set was_finalized[] back to true. :)
#     end
#     ts = ReTestItems.runtestitem(ti7; finish_test=true)
#     @test n_passed(ts) == 2

#     @test Main.was_finalized[] == false
#     ts = ti7 = nothing
#     GC.gc()
#     GC.gc()
#     @test Main.was_finalized[] == true
# end
=#

end # macros.jl testset
