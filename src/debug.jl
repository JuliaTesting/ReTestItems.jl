DEBUG_LEVEL::Int = 0

function setdebug!(level::Int)
    global DEBUG_LEVEL = level
    return nothing
end

"""
    withdebug(level::Int) do
        func()
    end
"""
function withdebug(f, level::Int)
    old = DEBUG_LEVEL
    try
        setdebug!(level)
        f()
    finally
        setdebug!(old)
    end
end

"""
    @debugv 1 "msg"
"""
macro debugv(level::Int, messsage)
    mod = pkgdir(@__MODULE__)
    quote
        if DEBUG_LEVEL >= $level
            _full_file = $String($(QuoteNode(__source__.file)))
            _file = $relpath(_full_file, $mod)
            _line = $(QuoteNode(__source__.line))
            msg = $(esc(messsage))
            $print("DEBUG @ $(_file):$(_line) | $msg\n")
        end
    end
end
