module TestEndExpr

export Pager, Page, good_read, bad_read

mutable struct Page
    content::Any
    @atomic pincount::Int
    function Page(x)
        p = new(x, 0) # 1 would be more realistic, but 0 keeps things simpler for our tests.
        @assert !isnothing(GLOBAL_PAGER[])
        @lock GLOBAL_PAGER[].lock push!(GLOBAL_PAGER[].pages, p)
        return p
    end
end

pin!(p::Page) = @atomic p.pincount += 1
unpin!(p::Page) = @atomic p.pincount -= 1

function read_content(p::Page)
    @assert p.pincount > 0
    return p.content
end

function good_read(p::Page)
    pin!(p)
    content = read_content(p)
    unpin!(p)
    return content
end

function bad_read(p::Page)
    pin!(p)
    content = read_content(p)
    #= No `unpin!(p)` call! =#
    return content
end

struct Pager
    pages::Vector{Page}
    lock::ReentrantLock
end
Pager() = Pager(Page[], ReentrantLock())

## `Pager` is free to delete pages if they are not pinned.
## Commented out since it is just for example and not used.
# cleanup!(p::Pager) = @lock p.lock deleteat!(p.pages, count_pins.(p.pages) .== 0)

count_pins(p::Page) = p.pincount
function count_pins(p::Pager)
    return @lock p.lock sum(count_pins, p.pages; init=0)
end

const GLOBAL_PAGER = Ref{Union{Nothing,Pager}}(nothing)
init_pager!() = isnothing(GLOBAL_PAGER[]) && (GLOBAL_PAGER[] = Pager())

end # module
