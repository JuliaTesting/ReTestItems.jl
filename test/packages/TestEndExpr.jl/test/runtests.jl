using ReTestItems
using TestEndExpr

const worker_init_expr = quote
    using TestEndExpr
    GLOBAL_PAGER[] = Pager()
end

# const test_end_expr = quote
#     p = GLOBAL_PAGER[]
#     (isnothing(p) || isempty(p.pages)) && return nothing
#     @testset "no pins left at end of test" begin
#         @test count_pins(p) == 0
#     end
# end

runtests(TestEndExpr; nworkers=1, worker_init_expr)
