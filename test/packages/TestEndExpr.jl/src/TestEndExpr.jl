module TestEndExpr

export GLOBAL_PAGER, Pager, Page, pin!, unpin!, read_content, count_pins

mutable struct Page
    content::Any
    @atomic pincount::Int
    function Page(x)
        p = new(x, 0)
        @assert !isnothing(GLOBAL_PAGER[])
        push!(GLOBAL_PAGER[].pages, p)
        return p
    end
end

function pin!(p::Page)
    @atomic p.pincount += 1
end
function unpin!(p::Page)
    @atomic p.pincount -= 1
end
function read_content(p::Page)
    @assert p.pincount > 0
    return p.content
end
count_pins(p::Page) = p.pincount

struct Pager
    pages::Vector{Page}
end
Pager() = Pager(Page[])

function count_pins(p::Pager)
    return sum(count_pins, p.pages; init=0)
end

const GLOBAL_PAGER = Ref{Union{Nothing,Pager}}(nothing)

# function __init__()
#     GLOBAL_PAGER[] = Pager()
# end

end # module
