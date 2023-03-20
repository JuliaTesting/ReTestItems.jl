# MonoRepo.jl

MonoRepo.jl depends on some local (unregistered) packages that live in `monorepo_packages/`.

The dependency graph looks like:
- `MonoRepo` depends on `B` and `C`
- `C` depends on `D` (so `D` is in the `MonoRepo` Manifest.toml)
- `C` has a test-dependency on `Example` (so `Example` is not in the `MonoRepo` Manifest.toml)

The testing situation is:
- `MonoRepo` and `C` use ReTestItems.jl
- `B` and `D` just use Test.jl
- Tests for all packages should pass.
- `runtests(MonoRepo)` should only run the tests for `MonoRepo` (and not also `B`, `C`, `D`)
- From the `MonoRepo` environment (`Pkg.activate(pkgdir(MonoRepo))`) we should be able to run the tests for `C` via `runtests(C)`.
    - This requires `runtests` correctly activating the test environment for `C` in order to have the test-only dependency `Example`.
