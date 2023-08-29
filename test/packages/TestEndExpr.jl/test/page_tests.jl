@testitem "correct usage" begin
    p = Page("Once upon a time")
    # `good_read` successfully reads the page and leaves it unpinned.
    @test good_read(p) == "Once upon a time"
end

@testitem "incorrect usage" begin
    p = Page("A long time ago")
    # `bad_read` successfully reads the page *but forgets to unpin it!*
    @test bad_read(p) == "A long time ago"
end
