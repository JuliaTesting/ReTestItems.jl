using Base.JuliaSyntax: JuliaSyntax, ParseError, ParseStream, @K_str
using Base.JuliaSyntax: any_error, build_tree, first_byte, kind, parse!, peek_full_token, peek_token
using StringViews

function include_test_file(ti_filter::TestItemFilter, path::String)
    bytes = read(path)
    stream = ParseStream(bytes)
    line_starts = Int32[Int32(i) for (i, x) in enumerate(bytes) if x == 0x0a] # :(
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path # This is also done by Base.include
    try
        @inbounds while true
            JuliaSyntax.bump_trivia(stream, skip_newlines=true)
            t = peek_token(stream, 1)
            k = kind(t)
            k == K"EndMarker" && break
            line = _source_line_index(line_starts, first_byte(stream))
            if k == K"@"
                tf = peek_full_token(stream, 2)
                v = @view(bytes[tf.first_byte:tf.last_byte])
                if     v == b"testitem" ; _eval_test_item_stream(stream, path, line, ti_filter, bytes)
                elseif v == b"testsetup"; _eval_test_setup_stream(stream, path, line)
                elseif v == b"test_rel" ; _eval_test_rel_stream(stream, path, line, ti_filter, bytes)
                else
                    error("Test files must only include `@testitem` and `@testsetup` calls, got an `@$(StringView(v))` at $(path):$(line)") # TODO
                end
            else
                error("Test files must only include `@testitem` and `@testsetup` calls, got a $t at $(path):$(line)") # TODO
            end
            empty!(stream) # TODO: SourceFile created on a reset stream always start line number at 1
        end
    finally
        delete!(tls, :SOURCE_PATH)
    end
end

@inline function _source_line_index(line_starts, bytes_pos)
    lineidx = searchsortedfirst(line_starts, bytes_pos)
    return (lineidx < lastindex(line_starts)) ? lineidx : lineidx-1
end

# unconditionally eval
function _eval_test_setup_stream(stream, path, line)
    parse!(stream; rule=:statement)
    ast = build_tree(Expr, stream;  filename=path, first_line=line)
    Core.eval(Main, ast)
    return nothing
end

# test_rel -> apply ti_filter on the parsed ast
function _eval_test_rel_stream(stream, path, line, ti_filter::TestItemFilter, bytes)
    parse!(stream; rule=:statement)
    if !(ti_filter.name isa Nothing)
        @inbounds for (i, token) in enumerate(stream.tokens)
            if kind(token) == K"Identifier"
                fbyte = JuliaSyntax.token_first_byte(stream, i)
                lbyte = JuliaSyntax.token_last_byte(stream, i)
                if @view(bytes[fbyte:lbyte]) == b"name"
                    fbyte = JuliaSyntax.token_first_byte(stream, i + 3)
                    lbyte = JuliaSyntax.token_last_byte(stream, i + 3)
                    name = StringView(@view(bytes[fbyte:lbyte]))
                    _contains(name, ti_filter.name) && break
                    return nothing
                end
            end
        end
    end
    ast = build_tree(Expr, stream; filename=path, first_line=line)
    any_error(stream) && throw(ParseError(stream, filename=path))
    filtered = __filter_rai(ti_filter, ast)::Union{Nothing, Expr}
    filtered === nothing || Core.eval(Main, filtered::Expr)
    return nothing
end

# like above, but tries to avoid parsing the ast if it sees from the name identifier token
# it won't pass the filter
function _eval_test_item_stream(stream, path, line, ti_filter::TestItemFilter, bytes)
    if !(ti_filter.name isa Nothing)
        name_t = peek_full_token(stream, 4) # 3 was '\"'
        name = @inbounds StringView(@view(bytes[name_t.first_byte:name_t.last_byte]))
        parse!(stream; rule=:statement)
        _contains(name, ti_filter.name) || return nothing
    else
        parse!(stream; rule=:statement)
    end

    ast = build_tree(Expr, stream; filename=path, first_line=line)
    any_error(stream) && throw(ParseError(stream, filename=path))
    filtered = __filter_ti(ti_filter, ast)::Union{Nothing, Expr}
    filtered === nothing || Core.eval(Main, filtered::Expr)
    return nothing
end

@inline _contains(s::AbstractString, pattern::Regex) = occursin(pattern, s)
@inline _contains(s::AbstractString, pattern::AbstractString) = s == pattern
