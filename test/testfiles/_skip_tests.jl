@testitem "1" begin
    @test true
end
@testitem "2" skip=true begin
    @test true
end
@testitem "3" skip=VERSION < v"2" begin
    @test true
end
@testitem "4" skip=VERSION > v"2" begin
    @test true
end
@testitem "5" skip=:(using Example; Example.domath(1) isa Number) begin
    @test true
end
# @testitem "5b" skip=:(using Base; Example.domath(1) isa Number) begin
#     @test true
# end
# @testitem "6" skip=:(1+1) begin
#     @test true
# end
