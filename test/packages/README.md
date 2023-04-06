# test/packages/

This directory contains fake packages which act as integration tests for ReTestItems.jl functionality.
These packages should have tests that all pass when run either via `ReTestItems.runtests` or via `Pkg.test`,
with the exception of `DontPass.jl` which is explicitly for testing our handling of tests that do not succeed.

The tests for these packages should be run as part of the ReTestItems.jl tests.
See `test/integrationtests.jl`.

- *DontPass.jl* - A package which has tests that fail or error in various ways.
  - NOTE: when adding new failure/error cases, you must also increment the counters in `test/integrationtests.jl`
- *NoDeps.jl* - A package that has no dependencies, and just has some simple `@test`s.
- *TestsInSrc.jl* - A package which has all of its `@testitems` in the `src/` directory.
- *TestProjectFile.jl* - A package which has test-only dependencies declared in a `test/Project.toml`.
- *MonoRepo.jl* - A package which depends on local, unregistered sub-packages. See `MonoRepo.jl/README.md`.
