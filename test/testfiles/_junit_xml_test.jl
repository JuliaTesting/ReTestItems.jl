# One pass, one fails
@testitem "testitem1" begin
    @test 1 == 1
    @test 2 == 3
end

# Multiple issues: A fail and an error
@testitem "testitem2" begin
    @test 3 == 3
    @testset "inner testset" begin
        @test 4 == 5
        @test "not a bool"
    end
end

# All pass
@testitem "testitem3" begin
    @test true
    @test 99 == 99
end

# One error
@testitem "testitem4" begin
    @testset "nested testset" begin
        y = x + 1
        @test y
    end
end

# One pass, one skip, one broken
@testitem "testitem5" begin
    @test true
    @test_skip :x == :x
    @test_broken :x == :y
end

# A failure and a testset with just one broken test
# Needed to test that when we have a failure/error, we still handle testsets with a single
# broken test correctly.
@testitem "testitem6" begin
    @test false
    @testset "nested broken" begin
        @test_broken :x == :y
    end
end
