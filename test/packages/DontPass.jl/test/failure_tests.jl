@testitem "failures" setup=[FailureSetup] begin
    @test false
    using LinearAlgebra
    @test LinearAlgebra.dot(rand(), rand()) < 0
    @test FailureSetup.FALSE
end

@testsetup module FailureSetup
    const FALSE = false
end
