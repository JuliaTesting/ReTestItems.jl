module ReTestItems

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
    setup::Vector{Any}
    file::String
    code::Any
    group::Union{String, Nothing}
end

"""
    @testitem TestItem "name" [tags...] [default_imports=true] [setup...] begin
        # code that will be run as a test
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    tags = Symbol[]
    setup = Any[]
    if !(length(exs) == 1 && exs[1] isa Expr && exs[1].head == :block)
        for ex in exs
            ex.head == :(=) || error("@testitem options must be passed as keyword arguments")
            if ex.args[1] == :tags
                tags = ex.args[2]
            elseif ex.args[1] == :default_imports
                default_imports = ex.args[2]
            elseif ex.args[1] == :setup
                setup = ex.args[2]
            else
                error("unknown @testitem keyword arg $(ex.args[1])")
            end
        end
    elseif isempty(exs)
        error("expected @testitem to have a body")
    end
    q = QuoteNode(exs[end])
    esc(quote
        $settls!($TestItem, $TestItem($nm, $tags, $default_imports, $setup, @__FILE__, $q, ReTestItems.gettestitemgroup()), $nm)
    end)
end

gettestitem(name) = task_local_storage(nameof(TestItem))[String(name)]

end # module ReTestItems
