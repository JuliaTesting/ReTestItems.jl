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

# FilteredVector applies a filtering function `f` to items
# when you try to `push!` and only puts if `f` returns true.
struct FilteredVector{T} <: AbstractVector{T}
    f::Any
    vec::Vector{T}
end

Base.push!(x::FilteredVector, y) = x.f(y) && push!(x.vec, y)
Base.size(x::FilteredVector) = size(x.vec)
Base.getindex(x::FilteredVector, i) = x.vec[i]

struct FileNode
    path::String
    testset::DefaultTestSet
    testitems::FilteredVector{TestItem} # sorted by line number within file
end

FileNode(path, f=default_shouldrun; verbose::Bool=false) = FileNode(path, DefaultTestSet(path; verbose), FilteredVector(f, TestItem[]))

Base.push!(f::FileNode, ti::TestItem) = push!(f.testitems, ti)

duration(ts::DefaultTestSet) = ts.time_end - ts.time_start

function Test.record(ts::DefaultTestSet, f::FileNode)
    foreach(ti -> Test.record(f.testset, ti.testset[]), f.testitems)
    # tot_duration = sum(duration(ti.testset[]) for ti in f.testitems; init=0.0)
    # f.testset.time_end = f.testset.time_start + tot_duration
    Test.record(ts, f.testset)
    return nothing
end

walk(f, fn::FileNode) = foreach(f, fn.testitems)

struct DirNode
    path::String
    testset::DefaultTestSet
    children::Vector{Union{FileNode, DirNode}} # sorted lexically by path
end

DirNode(path; verbose::Bool=false) = DirNode(path, DefaultTestSet(path; verbose), Union{FileNode, DirNode}[])

Base.push!(d::DirNode, child::Union{FileNode, DirNode}) = push!(d.children, child)

function Test.record(ts::DefaultTestSet, d::DirNode)
    foreach(child -> Test.record(d.testset, child), d.children)
    # tot_duration = sum(duration(child.testset) for child in d.children; init=0.0)
    # d.testset.time_end = d.testset.time_start + tot_duration
    Test.record(ts, d.testset)
    return nothing
end

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

function Test.finish(ti::TestItems)
    foreach(child -> Test.record(ti.graph.testset, child), ti.graph.children)
    # tot_duration = sum(duration(child.testset) for child in ti.graph.children; init=0.0)
    # ti.graph.testset.time_start = time() - tot_duration
    Test.finish(ti.graph.testset)
end

function get_starting_testitems(ti::TestItems, n)
    # we want to select n evenly spaced test items from ti.testitems
    testitems = Union{TestItem, Nothing}[ti.testitems[1]]
    len = length(ti.testitems)
    step = round(Int, len / n)
    for i in 2:(min(len, n))
        j = 1 + (i - 1) * step
        push!(testitems, ti.testitems[j])
    end
    for (i, t) in enumerate(testitems)
        @atomic t.scheduled_for_evaluation.value = true
        # mark eval_number
        t.eval_number[] = i
    end
    @atomic ti.count += n
    while length(testitems) < n
        push!(testitems, nothing)
    end
    return testitems
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
    stats::Stats
end
