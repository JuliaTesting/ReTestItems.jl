# Adapted from https://github.com/JuliaDiff/ChainRulesTestUtils.jl/blob/main/test/meta_testing_tools.jl
# Useful for testing that tests which are expected not to pass do indeed not pass.
# i.e. we want to run the tests for packages that purposely have tests fail/error, and
# (i) we want to double check that the expected fails/errors occurs
# (ii) do _not_ want expected fail/errors to cause ReTestItems' tests to fail/error
# This is not `@test_throws` etc, because we're not testing that the code fails/errors
# we're testing that _the tests themselves_ fail/error.

"""
    EncasedTestSet(desc, results) <: AbstractTestset

A custom testset that encases all test results within, not letting them out.
It doesn't let anything propagate up to the parent testset
(or to the top-level fallback testset, which throws an error on any non-passing result).
Not passes, not failures, not even errors.
This is useful for being able to observe the testsets results programatically;
without them triggering actual passes/failures/errors.
"""
mutable struct EncasedTestSet <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    n_passed::Int
end
EncasedTestSet(desc) = EncasedTestSet(desc, [], 0)

Test.record(ts::EncasedTestSet, t) = (push!(ts.results, t); t)
Test.record(ts::EncasedTestSet, t::Test.Pass) = (push!(ts.results, t); ts.n_passed += 1; t)

function Test.finish(ts::EncasedTestSet)
    if Test.get_testset_depth() != 0
        # Attach this test set to the parent test set *if* it is also an EncasedTestSet
        # Otherwise don't as we don't want to push the errors and failures further up.
        parent_ts = Test.get_testset()
        parent_ts isa EncasedTestSet && Test.record(parent_ts, ts)
        return ts
    end
    return ts
end

# DefaultTestSets don't store `Pass` results, so we are not able to capture those.
"""
    encased_testset(f)

`f` should be a function that takes no argument, and calls some code that used `@test`.
Invoking it via `encased_testset(f)` will prevent those `@test` being added to the
current testset, and will return the number of passes and a collection of all non-passing
test results.
"""
function encased_testset(f)
    # Specify testset type to hijack system
    ts = @testset EncasedTestSet "encased_testset" begin
        f()
    end
    return ts
end

_n_passed(x::Test.Result) = 0  # already recorded in the testset
_n_passed(ts) = ts.n_passed + _n_passed(ts.results)
function _n_passed(xs::Vector)
    if isempty(xs)
        return 0
    else
        return mapreduce(_n_passed, +, xs)
    end
end

n_passed(ts::EncasedTestSet) = _n_passed(ts)
n_tests(ts::EncasedTestSet) = _n_passed(ts) + length(non_passes(ts))

"extracts as flat collection of failures/errors from a (potential nested) testset"
_extract_nonpasses(x::Test.Result) = [x]
_extract_nonpasses(x::Test.Pass) = Test.Result[]
_extract_nonpasses(ts::EncasedTestSet) = _extract_nonpasses(ts.results)
_extract_nonpasses(ts::Test.DefaultTestSet) = _extract_nonpasses(ts.results)
function _extract_nonpasses(xs::Vector)
    if isempty(xs)
        return Test.Result[]
    else
        return mapreduce(_extract_nonpasses, vcat, xs)
    end
end

failures(results) = filter(res -> res isa Test.Fail, results)
errors(results) = filter(res -> res isa Test.Error, results)

non_passes(ts::EncasedTestSet) = _extract_nonpasses(ts)
failures(ts::EncasedTestSet) = failures(_extract_nonpasses(ts))
errors(ts::EncasedTestSet) = errors(_extract_nonpasses(ts))

all_passed(ts::EncasedTestSet) = isempty(non_passes(ts))
