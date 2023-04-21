## test/

This directory contains the test for `ReTestItems.jl`.

The tests themselves are defined in the files at the root of this directory.
Files not run directly, i.e. not `include`d in `runtests.jl` but instead included by some other test file, have names starting with a underscore, e.g. `_integration_test_tools.jl`.

Subdirectories contain files that _help_ test the package in some way (these files are also not run directly):
- `testfiles/` contains files that _use_ ReTestItems to define tests. They are used for integration tests.
- `packages/` contains packages that _use_ ReTestItems to define and run tests. They are used for integration tests
- `references/` contains reference files for testing the JUnit functionality.

### Adding tests

Please add tests when contributing changes.
All tests should be run using the `Test` stdlib and be added to a file at the root of this directory.
If a new file is added to the `src/` code, please add tests in a new file with the same name in `test/`.
Otherwise, please add tests to an existing file:
- `integrationtests.jl` for testing `runtests`
- `internals.jl` for testing internal helper functions
- `macros.jl` for testing `@testitem` or `@testsetup`
- `workers.jl` for testing code in `src/workers.jl`
- `junit_xml.jl` for testing code in `src/junit_xml.jl`
- `log_capture.jl` for testing code in `src/log_capture.jl`

If making changes to `src/junit_xml.jl` that change what is written to the XML files, the reference files will likely need updating.
These files can be updated automatically for you by running the tests in an interactive session (e.g. `include("junit_xml.jl")`);
when the reference tests fail you will be asked if you want to update the reference files.
You must take care to make sure the reference files are only ever changed on purpose, and then _ask for careful review of the changes to these files when opening a PR_.

If add more tests for `ReTestItems.runtests`, then usually you will want to add a new file in `testfiles/` which defines tests using `@testitem`, then in `integrationtests.jl` capture the result of calling `runtests("testfiles/_my_new_tests.jl")` and testing the results are as expected. If adding tests for something that can only be tested in the context of a package (e.g. testing that `runtests` handles test-only dependencies as expected, then you will likely want to add a new package to `packages/`.

When opening a PR, package maintainers can help guide you on how best to add tests.

### Running tests

The tests are run using Test.jl (not ReTestItems.jl itself).

Since we use `Test` for the testing of this package, we have to live with some of the limitations that `ReTestItems` tries to solve...
- there's no easy way to run a subset of tests when developing locally,
  but we do _try_ to keep each individual file independently runnable, e.g.
    ```julia
    # cd test/
    # julia --project
    using TestEnv; TestEnv.activate() # make sure test dependencies available
    include("test/internals.jl")
    ```
- there's no capturing of the logs output by tests, and often the tests are purposefully triggering failures, errors or warning (and testing we output or handle these things as expected) which makes the logs very noisy.
  Usually it's best to let the tests complete and rely on the final table of results to indicate if any tests didn't succeed, then searching for the name of the failing test in the logs, rather than trying to understand the logs as they come in.
