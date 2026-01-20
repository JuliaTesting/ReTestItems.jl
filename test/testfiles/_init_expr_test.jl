@testitem "init_expr sets global" begin
    # This test checks that `init_expr` was run before this testitem.
    # The init_expr should set `Main.INIT_EXPR_RAN` to `true`.
    @test isdefined(Main, :INIT_EXPR_RAN)
    @test Main.INIT_EXPR_RAN == true
end
