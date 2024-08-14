struct TestItemFilter{
        F<:Function,
        T<:Union{Nothing,Symbol,AbstractVector{Symbol}},
        N<:Union{Nothing,AbstractString,Regex}
} <: Function
    shouldrun::F
    tags::T
    name::N
    strict::Bool  # TODO: hardcode `strict=true`
end

# Use a custom struct so accessing a non-existent field (i.e. trying to filer on anything
# other than `name` or `tags`) gives a somewhat informative error.
struct TestItemMetadata
    name::String
    tags::Vector{Symbol}
end

# TODO: restrict this to `TestItemMetadata` when we hardcode `strict=true`
function (f::TestItemFilter)(ti::Union{TestItem,TestItemMetadata})
    if f.strict
        return true
    else
        return f.shouldrun(ti)::Bool && _shouldrun(f.tags, ti) && _shouldrun(f.name, ti)
    end
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
    is_retestitem_macrocall(expr, f.strict) || _throw_not_macrocall(expr)
    expr = filter_testitem(f, expr)
    return expr
end

# Filter out `@testitem` calls based on the `name` and `tags` keyword passed to `runtests`.
# Any other macro calls (e.g. `@testsetup`) are left as is.
# If the `@testitem` call is not as expected, it is left as is so that it throws an error.
#
# If the filter function `f` returns `true`, keep the `@testitem` call, otherwise remove it.
# Replacing the expression with `nothing` effectively removes it from the file.
# `Base.include` will still call `Core.eval(M, nothing)` which has a tiny overhead,
# but less than `Core.eval(M, :())`. We could instead replace `Base.include` with a
# custom function that doesn't call `Core.eval(M, expr)` if `expr === nothing`, but
# using `Base.include` means we benefit from improvements made upstream rather than
# having to maintain our own version of that code.
function filter_testitem(f, expr)
    @assert expr.head == :macrocall
    if expr.args[1] !== Symbol("@testitem")
        return expr
    end
    # `@testitem` have have at least: macro_name, line_number, name, body
    length(expr.args) < 4 && return expr
    name = try_get_name(expr)
    name === nothing && return expr
    tags = try_get_tags(expr)
    tags === nothing && return expr
    ti = TestItemMetadata(name, tags)
    return f(ti) ? expr : nothing
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

# check if the expression is a macrocall as expected. if `strict` is `true`, then we allow
# only `@testitem` and `@testsetup` calls, since these are all that are officially
# supported (and in future we intend to enforce `strict` mode).
function is_retestitem_macrocall(expr::Expr, strict::Bool)
    if expr.head == :macrocall
        name = expr.args[1]
        if strict
            return name === Symbol("@testitem") || name === Symbol("@testsetup")
        else
            # we allow any macro that expands to be an `@testitem`... but we can still
            # guard against the most common typos that we know aren't `@testitem`s
            return name !== Symbol("@testset") && name !== Symbol("@test")
        end
    else
        return false
    end
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
