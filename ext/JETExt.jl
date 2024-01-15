module JETExt

import JET, ReTestItems, Test

function _analyze_toplevel(ex, file, mode, ignore_modules)
    toplevelex = Expr(:toplevel, ex)
    analyzer = JET.JETAnalyzer(; mode, ignore_missing_comparison=true)
    config = JET.ToplevelConfig(; concretization_patterns = [])
    res = JET.virtual_process(toplevelex, file, analyzer, config)
    return JET.JETToplevelResult(analyzer, res, "analyze_toplevel"; mode, ignore_modules, target_defined_modules=false)
end

function ReTestItems.jet_test(ti::ReTestItems.TestItem, mod_expr::Expr, jet::Symbol)
    jet in (:skip, :none) && return nothing
    onfail(::Function, ::Test.Pass) = nothing
    onfail(f::Function, ::Test.Fail) = f()

    @assert mod_expr.head === :module "Expected the test item expression to be wrapped in a module, got $(repr(mod_expr.head))"
    Test.@testset "JET $(repr(jet)) mode" begin
        result = _analyze_toplevel(mod_expr, ti.file, jet, (JET.AnyFrameModule(Test), JET.AnyFrameModule(JET)))
        reports = JET.get_reports(result)
        no_jet_errors = isempty(reports)
        onfail(Test.@test no_jet_errors) do
            JET.print_reports(
                stdout,
                reports,
                # Remove the name of the module JET uses for virtualization the code and the name of the module
                # we wrap the test items in.
                JET.gen_postprocess(result.res.actual2virtual) ∘ x->replace(x, string("var\"", mod_expr.args[2], "\"") => ""),
            )
        end
    end
    return nothing
end

end
