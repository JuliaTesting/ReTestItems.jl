@testsetup module Constants
    const DEF = 1
    export DEF
end

@testitem "Test with JET on" jet=:basic setup=[Constants] begin
    using .Threads: @spawn

    @test DEF+1 == 2

    function foo()
        r = Ref(2)
        @spawn ($(r)[] += UNDEF)
        sleep(0.5)
        return r[]
    end
    @test foo() == 2
end

@testitem "Test with JET off" setup=[Constants] begin
    using .Threads: @spawn

    @test DEF+1 == 2

    function foo()
        r = Ref(2)
        @spawn ($(r)[] += UNDEF)
        sleep(0.5)
        return r[]
    end
    @test foo() == 2
end
