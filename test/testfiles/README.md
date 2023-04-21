## test/testfiles/

This directory contains files which _help_ test ReTestItems.jl functionality.

They should define tests _using ReTestItems_, i.e. using `@testitem` and `@testsetup`,
so we can call `runtests("testfiles/_some_tests.jl")` and check `runtests` behaves as expected.

These files should be _used by_ the tests in `test/integrationtests.jl`.
