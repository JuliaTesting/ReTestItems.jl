using ReTestItems, PkgUsingJET

runtests(PkgUsingJET; verbose_results=true, nworkers=1)
runtests(PkgUsingJET; verbose_results=true, nworkers=1, worker_init_expr=quote import JET end)
