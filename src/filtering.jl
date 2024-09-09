# Use a custom struct so accessing a non-existent field (i.e. trying to filer on anything
# other than `name` or `tags`) gives a somewhat informative error.
struct TestItemMetadata
    name::String
    tags::Vector{Symbol}
end

struct TestItemFilter{
        F<:Function,
        T<:Union{Nothing,Symbol,AbstractVector{Symbol}},
        N<:Union{Nothing,AbstractString,Regex}
} <: Function
    shouldrun::F
    tags::T
    name::N
end

function (f::TestItemFilter)(ti::TestItemMetadata)
    return f.shouldrun(ti)::Bool && _shouldrun(f.tags, ti) && _shouldrun(f.name, ti)
end

_shouldrun(name::AbstractString, ti) = name == ti.name
_shouldrun(pattern::Regex, ti) = contains(ti.name, pattern)
_shouldrun(tags::AbstractVector{Symbol}, ti) = issubset(tags, ti.tags)
_shouldrun(tag::Symbol, ti) = tag in ti.tags
_shouldrun(::Nothing, ti) = true

# Filter the AST before the code is evaluated.
# Called when a `TestItemFilter` is passed as the first argument to `Base.include`.
function (f::TestItemFilter)(expr::Expr)
    if Meta.isexpr(expr, :error)
        # If the expression failed to parse, most user-friendly to throw the ParseError,
        # rather than report an error about using only `@testitem` or `@testsetup`.
        Core.eval(Main, expr)
    end
    is_retestitem_macrocall(expr) || _throw_not_macrocall(expr)
    expr = filter_testitem(f, expr)
    return expr
end

function _throw_not_macrocall(expr)
    # `Base.include` sets the `:SOURCE_PATH` before the `mapexpr` is first called
    file = get(task_local_storage(), :SOURCE_PATH, "unknown")
    msg = """
    Test files must only include `@testitem` and `@testsetup` calls.
    In $(repr(file)) got:
        $(Base.remove_linenums!(expr))
    """
    error(msg)
end

# Filter out `@testitem` calls based on the `name` and `tags` keyword passed to `runtests`.
# Any other macro calls (e.g. `@testsetup`) are left as is.
# If the `@testitem` call is not as expected, it is left as is so that it throws an error.
#
# Replacing the expression with `nothing` effectively removes it from the file.
# `Base.include` will still call `Core.eval(M, nothing)` which has a tiny overhead,
# but less than `Core.eval(M, :())`. We could instead replace `Base.include` with a
# custom function that doesn't call `Core.eval(M, expr)` if `expr === nothing`, but
# using `Base.include` means we benefit from improvements made upstream rather than
# having to maintain our own version of that code.
function filter_testitem(f, expr)
    @assert expr.head == :macrocall
    macro_name = expr.args[1]
    if macro_name === Symbol("@testitem")
        # `@testitem` have have at least: macro_name, line_number, name, body
        length(expr.args) < 4 && return expr
        name = try_get_name(expr)
        name === nothing && return expr
        tags = try_get_tags(expr)
        tags === nothing && return expr
        ti = TestItemMetadata(name, tags)
        return f(ti) ? expr : nothing
    elseif macro_name === Symbol("@testsetup")
        return expr
    elseif macro_name === ___RAI_MACRO_NAME_DONT_USE # TODO: drop this branch when we can
        return __filter_rai(f, expr)
    end
end

# Extract the name from a `@testitem`, return `nothing` if name is not of the expected type.
function try_get_name(expr::Expr)
    @assert expr.head == :macrocall && expr.args[1] == Symbol("@testitem")
    name = expr.args[3]
    return name isa String ? name : nothing
end

# Extract the tags from a `@testitem`, return `nothing` if tags is not of the expected type.
# The absence of a `tags` keyword is the same as setting `tags=[]`
function try_get_tags(expr::Expr)
    @assert expr.head == :macrocall && expr.args[1] == Symbol("@testitem")
    tags = Symbol[]
    for args in expr.args[4:end]
        if args isa Expr && args.head == :(=) && args.args[1] == :tags
            tags_arg = args.args[2]
            if tags_arg isa Expr && tags_arg.head == :vect
                for tag in tags_arg.args
                    if tag isa QuoteNode && tag.value isa Symbol
                        push!(tags, tag.value)
                    else
                        return nothing
                    end
                end
            else
                return nothing
            end
        end
    end
    return tags
end

# Macro used by RAI (corporate sponsor of this package)
# TODO: drop support for this when RAI codebase is fully switched to ReTestItems.jl
const ___RAI_MACRO_NAME_DONT_USE = Symbol("@test_rel")
function __filter_rai(f, expr)
    @assert expr.head == :macrocall && expr.args[1] == ___RAI_MACRO_NAME_DONT_USE
    name = nothing
    tags = Symbol[]
    for args in expr.args[2:end]
        if args isa Expr && args.head == :(=) && args.args[1] == :name && args.args[2] isa String
            name = args.args[2]
        elseif args isa Expr && args.head == :(=) && args.args[1] == :tags
            tags_arg = args.args[2]
            if tags_arg isa Expr && tags_arg.head == :vect
                for tag in tags_arg.args
                    if tag isa QuoteNode && tag.value isa Symbol
                        push!(tags, tag.value)
                    else
                        return expr
                    end
                end
            else
                return expr
            end
        end
    end
    name === nothing && return expr
    ti = TestItemMetadata(name, tags)
    return f(ti) ? expr : nothing
end

# Check if the expression is a macrocall as expected.
# NOTE: Only `@testitem` and `@testsetup` calls are officially supported.
function is_retestitem_macrocall(expr::Expr)
    if expr.head == :macrocall
        name = expr.args[1]
        return name === Symbol("@testitem") || name === Symbol("@testsetup") || name === ___RAI_MACRO_NAME_DONT_USE
    else
        return false
    end
end
