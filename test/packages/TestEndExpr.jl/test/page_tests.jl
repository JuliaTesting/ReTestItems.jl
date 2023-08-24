@testitem "correct usage" begin
    p = Page("Once upon a time")
    pin!(p)
    content = read_content(p)
    unpin!(p)
    @test content == "Once upon a time"
end
@testitem "incorrect usage" begin
    p = Page("A long time ago")
    pin!(p)
    content = read_content(p)
    #= No unpin! call =#
    @test content == "A long time ago"
end
