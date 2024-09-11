"""
    TestSetupModules()

A set of test setups.
Used to keep track of which test setups have been evaluated on a given process.
"""
struct TestSetupModules
    lock::ReentrantLock
    modules::Dict{Symbol, Module} # set of @testsetup modules that have already been evaled
end

TestSetupModules() = TestSetupModules(ReentrantLock(), Dict{Symbol, Module}())

"""
    TestContext()

A context for test setups. Used to keep track of
`@testsetup`-expanded `TestSetup`s and a `TestSetupModules`
for a given process; used in `runtestitem` to ensure
any setups relied upon by the `@testitem` are evaluated
on the process that will run the test item.
"""
mutable struct TestContext
    # name of overall project we're eval-ing in
    projectname::String
    ntestitems::Int
    # name => eval'd code
    setups_evaled::TestSetupModules
    # user of TestContext must create and set the
    # TestSetupModules explicitly, since they must be process-local
    # and shouldn't be serialized across processes
    TestContext(name, ntestitems) = new(name, ntestitems)
end

struct FileNode
    path::String
    testset::DefaultTestSet
    junit::Union{JUnitTestSuite,Nothing}
    testitems::Vector{TestItem} # sorted by line number within file
end

function FileNode(path, f=Returns(true); report::Bool=false, verbose::Bool=false)
    junit = report ? JUnitTestSuite(path) : nothing
    return FileNode(path, DefaultTestSet(path; verbose), junit, TestItem[])
end

Base.push!(f::FileNode, ti::TestItem) = push!(f.testitems, ti)

walk(f, fn::FileNode) = foreach(f, fn.testitems)

struct DirNode
    path::String
    testset::DefaultTestSet
    junit::Union{JUnitTestSuites,Nothing}
    children::Vector{Union{FileNode, DirNode}} # sorted lexically by path
end

function DirNode(path; verbose::Bool=false, report::Bool=false)
    junit = report ? JUnitTestSuites(path) : nothing
    return DirNode(path, DefaultTestSet(path; verbose), junit, Union{FileNode, DirNode}[])
end

Base.push!(d::DirNode, child::Union{FileNode, DirNode}) = push!(d.children, child)

walk(f, dn::DirNode) = foreach(x -> walk(f, x), dn.children)

function prune!(dn::DirNode)
    # remove empty directories
    for i in length(dn.children):-1:1
        child = dn.children[i]
        if child isa DirNode
            prune!(child)
            if isempty(child.children)
                deleteat!(dn.children, i)
            end
        elseif child isa FileNode && isempty(child.testitems)
            deleteat!(dn.children, i)
        end
    end
    # now that they're pruned, sort children by path
    sort!(dn.children, by=x -> x.path)
    return nothing
end

mutable struct TestItems
    graph::Union{DirNode, FileNode}
    # testitems are stored in a flat list for easy iteration
    # and lookup by id
    # they are populated once the full graph is done by doing
    # a depth-first traversal of the graph
    testitems::Vector{TestItem} # frozen once flatten_testitems! is called
    @atomic count::Int # number of testitems that have been taken for eval so far
end

TestItems(graph) = TestItems(graph, TestItem[], 0)

###
### record results
###

function record_results!(ti::TestItems)
    foreach(ti.graph.children) do child
        record_results!(ti.graph, child)
    end
end

function record_results!(dir::DirNode, child_dir::DirNode)
    @debugv 1 "Recording dir $(repr(child_dir.path)) to dir $(repr(dir.path))"
    foreach(child_dir.children) do child
        record_results!(child_dir, child)
    end
    Test.record(dir.testset, child_dir.testset)
    junit_record!(dir.junit, child_dir.junit)
end

function record_results!(dir::DirNode, file::FileNode)
    @debugv 1 "Recording file $(repr(file.path)) to dir $(repr(dir.path))"
    foreach(file.testitems) do ti
        record_results!(file, ti)
    end
    Test.record(dir.testset, file.testset)
    junit_record!(dir.junit, file.junit)
end

function record_results!(file::FileNode, ti::TestItem)
    @debugv 1 "Recording TestItem $(repr(ti.name)) to file $(repr(file.path))"
    # Always record last try as the final status, so a pass-on-retry is a pass.
    Test.record(file.testset, last(ti.testsets))
    junit_record!(file.junit, ti)
end

# DirNode and FileNode have `junit=nothing` when no report is needed.
junit_record!(::Nothing, ::Nothing) = nothing
junit_record!(::Nothing, _) = nothing
junit_record!(_, ::Nothing) = nothing

Test.finish(ti::TestItems) = Test.finish(ti.graph.testset)

function get_starting_testitems(ti::TestItems, n)
    # we want to select n evenly spaced test items from ti.testitems
    len = length(ti.testitems)
    step = max(1, len / n)
    testitems = [ti.testitems[round(Int, i)] for i in 1:step:len]
    @debugv 2 "get_starting_testitems" len n allunique(testitems)
    @assert length(testitems) == min(n, len) && allunique(testitems)
    for (i, t) in enumerate(testitems)
        @atomic t.scheduled_for_evaluation.value = true
        # mark eval_number
        t.eval_number[] = i
    end
    @atomic ti.count += n
    return [testitems; fill(nothing, n - length(testitems))]
end

function flatten_testitems!(ti::TestItems)
    walk(ti.graph) do x
        push!(ti.testitems, x)
    end
end

# i is the index of the last test item that was run
function next_testitem(ti::TestItems, i::Int)
    len = length(ti.testitems)
    n = len
    while n > 0
        i += 1
        if i > len
            i = 1 # wrap around
        end
        t = ti.testitems[i]
        # try to atomically mark a test item as scheduled for evaluation
        (; old, success) = @atomicreplace :monotonic t.scheduled_for_evaluation.value false => true
        if success
            t.eval_number[] = @atomic :monotonic ti.count += 1
            return t
        end
        n -= 1
    end
    return nothing
end

struct TestItemResult
    testset::DefaultTestSet
    stats::PerfStats
end
