function walkdir2(root; topdown=true, follow_symlinks=false, onerror=throw)
    function _walkdir(chnl, root)
        tryf(f, p) = try
                f(p)
            catch err
                isa(err, Base.IOError) || rethrow()
                try
                    onerror(err)
                catch err2
                    close(chnl, err2)
                end
                return
            end
        content = tryf(readdir, root)
        content === nothing && return
        dirs = Vector{eltype(content)}()
        files = Vector{eltype(content)}()
        for name in content
            path = joinpath(root, name)

            # If we're not following symlinks, then treat all symlinks as files
            if (!follow_symlinks && something(tryf(islink, path), true)) || !something(tryf(isdir, path), false)
                push!(files, name)
            else
                push!(dirs, name)
            end
        end

        if topdown
            push!(chnl, (root, dirs, files))
        end
        for dir in dirs
            _walkdir(chnl, joinpath(root, dir))
        end
        if !topdown
            push!(chnl, (root, dirs, files))
        end
        nothing
    end
    return Channel{Tuple{String,Vector{String},Vector{String}}}(chnl -> _walkdir(chnl, root), Inf, spawn=true)
end

function _include_string(mapexpr::Function, mod::Module, code::AbstractString,
                        filename::AbstractString="string")
    loc = LineNumberNode(1, Symbol(filename))
    try
        # ast = Base.JuliaSyntax.parseall(Expr, code, filename=filename)
        ast = Meta.parseall(code, filename=filename)
        @assert Meta.isexpr(ast, :toplevel)
        result = nothing
        line_and_ex = Expr(:toplevel, loc, nothing)
        for ex in ast.args
            if ex isa LineNumberNode
                loc = ex
                line_and_ex.args[1] = ex
                continue
            end
            ex = mapexpr(ex)
            if ex !== nothing
                # Wrap things to be eval'd in a :toplevel expr to carry line
                # information as part of the expr.
                line_and_ex.args[2] = ex
                Core.eval(mod, line_and_ex)
            end
        end
        return nothing
    catch exc
        # TODO: Now that stacktraces are more reliable we should remove
        # LoadError and expose the real error type directly.
        rethrow(LoadError(filename, loc.line, exc))
    end
end

function _include(mapexpr::Function, mod::Module, _path::AbstractString)
    # @noinline # Workaround for module availability in _simplify_include_frames
    path, prev = Base._include_dependency(mod, _path)
    for callback in Base.include_callbacks # to preserve order, must come before eval in include_string
        invokelatest(callback, mod, path)
    end
    code = read(path, String)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path
    try
        return _include_string(mapexpr, mod, code, path)
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
end
