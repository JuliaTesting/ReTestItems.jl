# test/packages/

This directory contains fake packages which act as integration tests for ReTestItems.jl functionality.
These packages should have tests that all pass when run either via `ReTestItems.runtests` or via `Pkg.test`.

- *NoDeps.jl* - A package that has no dependencies, and just has some simple `@tests` in the `test/runtests.jl`
- *TestsInSrc.jl* - A package which has all of its `@testitems` in the `src/` directory.
