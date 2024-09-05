# This file is incorrect usage of ReTestItems
# but we want to check that a failed `@testitem` used directly in a script
# means the script exists with a non-zero exit code.
using ReTestItems
@testitem "should fail" begin
    @test 1 == 2
end
