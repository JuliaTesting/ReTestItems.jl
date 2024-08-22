# name is not a String literal (it's an Expr, because of interpolation); should throw
@testitem "TI #$(1)" begin
    @test true
end
