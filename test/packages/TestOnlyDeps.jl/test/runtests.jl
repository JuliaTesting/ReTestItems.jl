using ReTestItems
using TestOnlyDeps

nworkers = parse(Int, get(ENV, "RETESTITEMS_NWORKERS", "1"))
@assert nworkers > 0
runtests(TestOnlyDeps; nworkers)
