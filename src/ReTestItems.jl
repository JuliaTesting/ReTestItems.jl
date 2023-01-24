module ReTestItems

using Test: Test, DefaultTestSet
using .Threads: @spawn

export @testitemgroup, @testsetup, @testitem,
       TestSetup, TestItem

# pass in a type T, value, and str key
# we get a Dict{String, T} from task_local_storage
# and set key => value
settls!(::Type{T}, val, str::String) where {T} =
    setindex!(get!(() -> Dict{String, T}(), task_local_storage(), nameof(T))::Dict{String, T}, val, str)

"""
    @testitemgroup name begin
        ...
    end

Temporarily sets a test item group name
in task local storage that test items will
pick up when their macro is expanded. Useful
for grouping test items together when multiple
test items are run together.
"""
macro testitemgroup(name, body)
    esc(quote
        task_local_storage(:__TEST_ITEM_GROUP__, $name) do
            $body
        end
    end)
end

# get any test item group that has been set in task_local_storage
gettestitemgroup() = get(task_local_storage(), :__TEST_ITEM_GROUP__, nothing)

struct TestSetup
    name::Symbol
    code::Any
end

"""
    @testsetup TestSetup begin
        # code that can be shared between @testitems
    end
"""
macro testsetup(name, code)
    name isa Symbol || error("expected `name` to be a valid module name")
    nm = QuoteNode(name)
    q = QuoteNode(code)
    esc(quote
        $settls!($TestSetup, $TestSetup($nm, $q), $(String(name)))
    end)
end

# retrieve a test setup by name
gettestsetup(name) = task_local_storage(nameof(TestSetup))[String(name)]

struct TestItem
    name::String
    tags::Vector{Symbol}
    default_imports::Bool
    setup::Vector{Symbol}
    file::String
    code::Any
    group::Union{String, Nothing}
end

const _TEST_ITEM_CHANNEL = Channel{Union{Nothing,TestItem}}(Inf)

"""
    @testitem TestItem "name" [tags...] [default_imports=true] [setup...] begin
        # code that will be run as a test
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    tags = Symbol[]
    setup = Any[]
    if length(exs) > 1
        for ex in exs[1:end-1]
            ex.head == :(=) || error("@testitem options must be passed as keyword arguments")
            if ex.args[1] == :tags
                tags = ex.args[2]
            elseif ex.args[1] == :default_imports
                default_imports = ex.args[2]
            elseif ex.args[1] == :setup
                setup = ex.args[2]
                @assert setup isa Expr "setup keyword must be passed a collection of testsetup names"
                setup = map(Symbol, setup.args)
            else
                error("unknown @testitem keyword arg $(ex.args[1])")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected @testitem to have a body")
    end
    q = QuoteNode(exs[end])
    esc(quote
        ti = $TestItem($nm, $tags, $default_imports, $setup, $(String(__source__.file)), $q, ReTestItems.gettestitemgroup())
        put!($_TEST_ITEM_CHANNEL, ti)
        return ti
    end)
end

gettestitem(name) = task_local_storage(nameof(TestItem))[String(name)]


function _src_and_test(root_dir)
    src_dir = joinpath(root_dir, "src")
    test_dir = joinpath(root_dir, "test")
    return (src_dir, test_dir)
end

function runtests()
    # TODO: check if we're in `.julia/environments/v#.#/` and bail if we are?
    @show dir = dirname(Base.active_project())
    return runtests(_src_and_test(dir)...)
end

function runtests(pkg::Module)
    dir = pkgdir(pkg)
    isnothing(dir) && error("Could not find directory for $pkg")
    return runtests(_src_and_test(dir)...)
end

function runtests(paths...)
    # @spawn include_testfiles!(paths...)
    include_testfiles!(paths...)
    put!(_TEST_ITEM_CHANNEL, nothing)
    # @spawn schedule_testitems!()
    schedule_testitems!()
end

include_testfiles!(paths...) = foreach(include_testfiles!, paths)
function include_testfiles!(path::String)
    for (root, dir, files) in walkdir(path)
        for file in files
            @show file
            endswith(file, "_test.jl") || continue
            filepath = joinpath(root, file)
            include(filepath)
        end
    end
    return nothing
end

function schedule_testitems!()
    while true
        ti = take!(_TEST_ITEM_CHANNEL)
        ti === nothing && break
        runitem(ti)
    end
end

function runitem(ti::TestItem)
    mod = Core.eval(Main, :(module $(gensym(ti.name)) end))
    if ti.default_imports
        Core.eval(mod, :(using Test))
        # TODO: know which package a TestItem belongs to.
        # if ti.package !== nothing
        #     Core.eval(mod, :(using $(ti.package)))
        # end
    end
    Test.push_testset(DefaultTestSet(ti.name; verbose=true))
    Core.eval(mod, ti.code)
    Test.finish(Test.pop_testset())
    return nothing
end

end # module ReTestItems
