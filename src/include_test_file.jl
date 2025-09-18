using JuliaSyntax: ParseStream, @K_str, build_tree, bump_trivia, kind, parse!, peek_full_token, peek_token
using StringViews

function include_test_file(ti_filter::TestItemFilter, path::String)
    bytes = read(path)
    stream = ParseStream(bytes)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path # This is also done by Base.include
    try
        while true
            bump_trivia(stream, skip_newlines=true)
            t = peek_token(stream, 1)
            k = kind(t)
            k == K"EndMarker" && break
            if k == K"@"
                tf = peek_full_token(stream, 2)
                v = @inbounds @view(bytes[tf.first_byte:tf.last_byte])
                if     v == b"testitem" ; _eval_from_stream(stream, path, ti_filter, bytes)
                elseif v == b"testsetup"; _eval_from_stream(stream, path)
                elseif v == b"test_rel" ; _eval_from_stream(stream, path, ti_filter)
                else
                    error("Test files must only include `@testitem` and `@testsetup` calls, got an `@$(StringView(v))` at $(path)") # TODO
                end
            else
                error("Test files must only include `@testitem` and `@testsetup` calls, got a $t at $(path)") # TODO
            end
            empty!(stream)
        end
    finally
        delete!(tls, :SOURCE_PATH)
    end
end

_contains(s::AbstractString, pattern::Regex) = occursin(pattern, s)
_contains(s::AbstractString, pattern::AbstractString) = s == pattern

# unconditionally eval
function _eval_from_stream(stream, path)
    parse!(stream; rule=:statement)
    ast = build_tree(Expr, stream;  filename=path)
    Core.eval(Main, ast)
    return nothing
end

# test_rel -> apply ti_filter on the parsed ast
function _eval_from_stream(stream, path, ti_filter::TestItemFilter)
    parse!(stream; rule=:statement)
    ast = build_tree(Expr, stream; filename=path)
    filtered = ti_filter(ast)::Union{Nothing, Expr}
    filtered === nothing || Core.eval(Main, filtered::Expr)
    return nothing
end

# like above, but tries to avoid parsing the ast if it sees from the name identifier token
# it won't pass the filter
function _eval_from_stream(stream, path, ti_filter::TestItemFilter, bytes)
    if ti_filter.name isa Nothing
        parse!(stream; rule=:statement)
        ast = build_tree(Expr, stream; filename=path)
        filtered = ti_filter(ast)::Union{Nothing, Expr}
        filtered === nothing || Core.eval(Main, filtered::Expr)
        return nothing
    end

    name_t = peek_full_token(stream, 4) # 3 was '\"'
    name = @inbounds StringView(@view(bytes[name_t.first_byte:name_t.last_byte]))
    parse!(stream; rule=:statement)
    if _contains(name, ti_filter.name)
        ast = build_tree(Expr, stream; filename=path)
        filtered = ti_filter(ast)::Union{Nothing, Expr}
        filtered === nothing || Core.eval(Main, filtered::Expr)
    end
    return nothing
end
