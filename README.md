[![CI](https://github.com/JuliaTesting/ReTestItems.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaTesting/ReTestItems.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/JuliaTesting/ReTestItems.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaTesting/ReTestItems.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

# ReTestItems.jl

A package for running `@testitem`s in parallel.

## Quickstart

Wrap your tests in the `@testitem` macro, place them in a file named `*_test.jl`, and use `runtests` to run them:

```julia
# test/arithmetic_tests.jl
@testitem "addition" begin
    @test 1 + 2 == 3
    @test 0 + 2 == 2
    @test -1 + 2 == 1
end
@testitem "multiplication" begin
    @test 1 * 2 == 2
    @test 0 * 2 == 0
    @test -1 * 2 == -2
end
```

```julia
julia> using ReTestItems

julia> runtests("test/arithmetic_tests.jl")
```

Run test-items in parallel on multiple processes by passing `nworkers`:

```julia
julia> runtests("test/arithmetic_tests.jl"; nworkers=2)
```

## Running tests

You can run tests using the [`runtests`](https://docs.juliahub.com/General/ReTestItems/stable/autodocs/#ReTestItems.runtests) function,
which will run all tests for the current active project.

```julia
julia> using ReTestItems

julia> runtests()
```

Test-items must be in files named with the suffix `_test.jl` or `_tests.jl`.
ReTestItems uses these file suffixes to identify which files are "test files";
all other files will be ignored by `runtests`.

`runtests` allows you to run a subset of tests by passing the directory or file path(s) you want to run.

```julia
julia> runtests(
           "test/Database/physical_representation_tests.jl",
           "test/PhysicalRepresentation/",
       )
```

For interactive sessions, all logs from the tests will be printed out in the REPL by default.
You can disable this by passing `logs=:issues` in which case logs from a test-item are only printed if that test-items errors or fails.
`logs=:issues` is also the default for non-interactive sessions.

```julia
julia> runtests("test/Database/"; logs=:issues)
```

#### Filtering tests

You can use the `name` keyword to select test-items by name.
Pass a string to select a test-item by its exact name,
or pass a regular expression (regex) to match multiple test-item names.

```julia
julia> runtests("test/Database/"; name="issue-123")

julia> runtests("test/Database/"; name=r"^issue")
```

You can pass `tags` to select test-items by tag.
When passing multiple tags a test-item is only run if it has all the requested tags.

```julia
# Run tests that are tagged as both `regression` and `fast`
julia> runtests("test/Database/"; tags=[:regression, :fast])
```

Filtering by `name` and `tags` can be combined to run only test-items that match both the name and tags.

```julia
# Run tests named `issue*` which also have tag `regression`.
julia> runtests("test/Database/"; tags=:regression, name=r"^issue")
```

## Writing tests

Tests must be wrapped in a [`@testitem`](https://docs.juliahub.com/General/ReTestItems/stable/autodocs/#ReTestItems.@testitem-Tuple{Any,%20Vararg{Any}}).
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

#### Test setup

If some test-specific code needs to be shared by multiple `@testitem`s, this code can be placed in a `module` and marked as [`@testsetup`](https://docs.juliahub.com/General/ReTestItems/stable/autodocs/#ReTestItems.@testsetup-Tuple{Any})
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

The `setup` is run once on each worker process that requires it;
it is not run before every `@testitem` that depends on the setup.

#### Skipping tests

The `skip` keyword can be used to skip a `@testitem`, meaning no code inside that test-item will run.
A skipped test-item logs that it is being skipped and records a single "skipped" test result, similar to `@test_skip`.

```julia
@testitem "skipped" skip=true begin
    @test false
end
```

If `skip` is given as an `Expr`, it must return a `Bool` indicating whether or not to skip the test-item.
This expression will be run in a new module similar to a test-item immediately before the test-item would be run.

```julia
# Don't run "orc v1" tests if we don't have orc v1
@testitem "orc v1" skip=:(using LLVM; !LLVM.has_orc_v1()) begin
    # tests
end
```

The `skip` keyword allows you to define the condition under which a test needs to be skipped,
for example if it can only be run on a certain platform.
See [filtering tests](#filtering-tests) for controlling which tests run in a particular `runtests` call.

#### Post-testitem hook

If there is something that should be checked after every single `@testitem`, then it's possible to pass an expression to `runtests` using the `test_end_expr` keyword.
This expression will be run immediately after each `@testitem`.

```julia
test_end_expr = quote
    @testset "global Foo unchanged" begin
        foo = get_global_foo()
        @test foo.changes == 0
    end
end
runtests("frozzle_tests.jl"; test_end_expr)
```

#### Worker process start-up

If there is some set-up that should be done on each worker process before it is used to evaluated test-items, then it is possible to pass an expression to `runtests` via the `worker_init_expr` keyword.
This expression will be run on each worker process as soon as it is started.

```julia
nworkers = 3
worker_init_expr = quote
    set_global_foo_memory_limit!(Sys.total_memory()/nworkers)
end
runtests("frobble_tests.jl"; nworkers, worker_init_expr)
```

## Summary

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
    - No explicit `include` of these files is required.
    - Files containing only `@testsetup`s can be named `*_testsetup.jl` or `*_testsetups.jl`,
      and these files will always be included.
    - Note that `test/runtests.jl` does not meet the naming convention, and should not itself contain `@testitems`.
4. Make sure your `test/runtests.jl` script calls `runtests`.
    - `test/runtests.jl` is the script run when you call `Pkg.test()` or `] test` at the REPL.
    - This script can have ReTestItems.jl run tests by calling `runtests`, for example
      ```julia
      # test/runtests.jl
      using ReTestItems, MyPackage
      runtests(MyPackage)
      ```
    - Pass to `runtests` any configuration you want your tests to run with, such as `retries`, `testitem_timeout`, `nworkers`, `nworker_threads`, `worker_init_expr`, `test_end_expr`.
      See the [`runtests`](https://docs.juliahub.com/General/ReTestItems/stable/autodocs/#ReTestItems.runtests) docstring for details.

---

### Contributing

Issues and pull requests are welcome!
New contributors should make sure to read the [ColPrac Contributor Guide](https://github.com/SciML/ColPrac).
For significant changes please [open an issue](https://github.com/JuliaTesting/ReTestItems.jl/issues) for discussion before opening a PR.
Information on adding tests is in the [test/README.md](test/README.md).
