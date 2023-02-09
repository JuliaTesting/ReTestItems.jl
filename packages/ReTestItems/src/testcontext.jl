"""
    TestSetupModules()

A set of test setups.
Used to keep track of which test setups have been evaluated on a given process.
"""
struct TestSetupModules
    lock::ReentrantLock
    modules::Dict{Symbol, Module} # set of @testsetup modules that have already been evaled
end

TestSetupModules() = TestSetupModules(ReentrantLock(), Dict{Symbol, Module}())

"""
    TestContext()

A context for test setups. Used to keep track of
`@testsetup`-expanded `TestSetup`s and a `TestSetupModules`
for a given process; used in `runtestitem` to ensure
any setups relied upon by the `@testitem` are evaluated
on the process that will run the test item.
"""
mutable struct TestContext
    # name of overall project we're eval-ing in
    projectname::String
    # name => eval'd code
    setups_evaled::TestSetupModules

    # user of TestContext must create and set the
    # TestSetupModules explicitly, since they must be process-local
    # and shouldn't be serialized across processes
    TestContext(name) = new(name)
end

# FilteredChannel applies a filtering function `f` to items
# when you try to `put!` and only puts if `f` returns true.
struct FilteredChannel{F, T}
    f::F
    ch::T
end

Base.put!(ch::FilteredChannel, x) = ch.f(x) && put!(ch.ch, x)
Base.take!(ch::FilteredChannel) = take!(ch.ch)
Base.close(ch::FilteredChannel) = close(ch.ch)
Base.close(ch::FilteredChannel, e::Exception) = close(ch.ch, e)
Base.isopen(ch::FilteredChannel) = isopen(ch.ch)

chan(ch::RemoteChannel) = channel_from_id(remoteref_id(ch))
chan(fch::FilteredChannel) = fch.ch
chan(ch::Channel) = ch
