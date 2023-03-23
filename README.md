# ReTestItems.jl

A package for parallel tests.

## Quickstart

Wrap your tests in the `@testitem` macro, place then in a file name `*_test.jl`, and use `runtests` to run them:

```julia
# my_tests.jl
@testitem "addition" begin
    @test 1 + 2 == 3
    @test 0 + 2 == 2
    @test -1 + 2 == 1
end
```

```julia
julia> using ReTestItems

julia> runtests("my_tests.jl")
```

## Running tests

You can run tests using the `runtests` function, which will run all tests for the current active project.

```julia
julia> using ReTestItems

julia> runtests()
```

Test files must be named with the suffix `_test.jl` or `_tests.jl`.
ReTestItems uses these file suffixes to identify which files are "test files";
all other files will be ignored by `runtests`.

`runtests` allows you to run a subset of tests by passing the directory or file path(s) you want to run.

```julia
julia> runtests(
           "test/Database/physical_representation_tests.jl",
           "test/PhysicalRepresentation/",
       )
```

You can use the `name` keyword, to select test-items by name.
Pass a string to select a test-item by its exact name,
or pass a regular expression (regex) to match multiple test-item names.

```julia
julia> runtests("test/Database/"; name="issue-123")

julia> runtests("test/Database/"; name=r"^issue")
```

By default, logs from the tests will be printed out in the REPL.
You can disable this by passing `verbose=false`.
When `verbose=false`, logs from a test-item are only printed if that test-items errors or fails.

```julia
julia> runtests("test/Database/"; verbose=false)
```

## Writing tests

Tests must be wrapped in a `@testitem`.
In most cases, a `@testitem` can just be used instead of a `@testset`, wrapping together a bunch of related tests:
```julia
@testitem "min/max" begin
    @test min(1, 2) == 1
    @test max(1, 2) == 2
end
```

The test-item's code is evaluated as top-level code in a new module,
so it can include imports, define new structs or helper functions, as well as declare `@test`s and `@testset`s.

```julia
@testitem "Do cool stuff" begin
    using MyPkgDep
    function really_cool_stuff()
        # ...
    end
    @testset "Cool stuff doing" begin
        @test really_cool_stuff()
    end
end
```

By default, `Test` and the package being tested will be imported into the `@testitem` automatically.

Since a `@testitem` is the block of code that will be executed, `@testitem`s cannot be nested.

If some test-specific code needs to be shared by multiple `@testitem`s, this code can be placed in a `module` and marked as `@testsetup`,
and the `@testitem`s can depend on it via the `setup` keyword.

```julia
@testsetup module TestIrrationals
    export PI, area
    const PI = 3.14159
    area(radius) = PI * radius^2
end
@testitem "Arithmetic" setup=[TestIrrationals] begin
    @test 1 / PI ≈ 0.31831 atol=1e-6
end
@testitem "Geometry" setup=[TestIrrationals] begin
    @test area(1) ≈ PI
end
```

### Summary

1. Write tests inside of an `@testitem` block.
    - These are like an `@testset`, except that they must contain all the code they need to run;
      any imports or definitions required for the tests must be inside the `@testitem`.
    - A `@testset` can still be used to add structure to your tests, but all `@testset`s must be inside an `@testitem`.
      These nested `@testset`s can add structure to the reporting, but serve no other purpose.
    - Tests that might previously have had imports and `struct` or `function` definitions outside of an `@testset` should instead now declare these inside of a `@testitem`.
    - `@testitem` will be run in parallel (using whatever threads or workers are available to the current Julia process).
2. Write shared/re-used testing code in a `@testsetup module`
    - If you want to split tests up into multiple `@testitem` (so they can run in parallel), but also want to share common helper functions, types, or constants,
      then put the shared helper code in a module marked with `@testsetup`.
    - Each `@testsetup` will only be evaluated once per Julia process.
    - A `@testsetup module` is recommended to be used for sharing helper definitions or shared immutable data;
      not for initializing shared global state that is meant to be mutated (like starting a server).
      For example, a server should be explicitly started and stopped as needed in a `@testitem`, not started within a `@testsetup module`.
3. Write tests in files named `*_test.jl` or `*_tests.jl`.
    - ReTestItems scans the directory tree for any file with the correct naming scheme and automatically schedules for evaluation the `@testitem` they contain.
    - Files without this naming convention will not run.
    - Test files can reside in either the `src/` or `test/` directory,
      so long as they are named like `src/sorted_set_tests.jl` (note the `_tests.jl` suffix).
    - No explicit `include` of these files is required;
    - Note that `test/runtests.jl` does not meet the naming convention, and should not itself contain `@testitems`.
4. Make sure your `test/runtests.jl` script calls `runtests`.
    - `test/runtests.jl` is the script run when you call `Pkg.test()` or `] test` at the REPL.
    - This script can have ReTestItems.jl run tests by calling `runtests`, for example
      ```julia
      # test/runtests.jl
      using ReTestItems, MyPackage
      runtests(MyPackage)
      ```
