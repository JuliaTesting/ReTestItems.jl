using ReTestItems
using TestEndExpr

const worker_init_expr = quote
    using TestEndExpr: init_pager!
    init_pager!()
end

## This is the sort of `test_end_expr` we would want to run
## We don't use this here in the TestEndExpr.jl tests, so that all the tests pass.
## Instead we set in `ReTestItems/test/integrationtests.jl` so we can test
## that such a `test_end_expr` causes the tests to fail.
# const test_end_expr = quote
#     p = GLOBAL_PAGER[]
#     (isnothing(p) || isempty(p.pages)) && return nothing
#     @testset "no pins left at end of test" begin
#         @test count_pins(p) == 0
#     end
# end

runtests(TestEndExpr; nworkers=1, worker_init_expr)
