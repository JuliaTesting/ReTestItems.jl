# TestEndExpr.jl

A package for the sake of testing the `test_end_expr` functionality of `ReTestItems.runtests`.

We want to emulate a situation where correct usage of a package requires users to uphold a certain invariant.
In this very simplified example, `Page` objects must be pinned via `pin!` when in use, and subsequently unpinned via `unpin!` when no longer in use; there must be an equal number of `pin!` and `unpin!` calls in order to avoid a memory leak.

We want to be able to write potentially very many `@testitem`s which test all sorts of functionality that use `Page`s under the hood.
But we also want to test that every such usage correctly upholds the invariant, i.e. no `Page` is left "pinned" at the end of the `@testitem`.

We could do that by manually adding something like `@test no_pages_pinned()` as the last line of every `@testitem`, but we might not want to rely on test authors remembering to do this.
So instead, we want to use `test_end_expr` to declare a block of code like `@test no_pages_pinned()` to automatically run at the end of every `@testitem`.

In the tests of this package, we define test-items that **pass** when run without such a `test_end_expr`, but at least one of the test-items **fails** when run with a `test_end_expr` testing that no pages are left pinned.
