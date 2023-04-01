module Workers

using Base: @lock
using Serialization
using Sockets

export Worker, remote_eval, remote_fetch, terminate!, WorkerTerminatedException

function try_with_timeout(f, timeout)
    cond = Threads.Condition()
    timer = Timer(timeout) do tm
        close(tm)
        ex = ErrorException("timed out after $timeout seconds")
        @lock cond notify(cond, ex; error=true)
    end
    Threads.@spawn begin
        try
            ret = $f()
            isopen(timer) && @lock cond notify(cond, ret)
        catch e
            isopen(timer) && @lock cond notify(cond, CapturedException(e, catch_backtrace()); error=true)
        finally
            close(timer)
        end
    end
    return @lock cond wait(cond) # will throw if we timeout
end

# RPC framework
struct Request
    mod::Symbol
    expr::Expr
    id::UInt64 # unique id for this request
    # if true, worker should terminate immediately after receiving this Request
    # ignoring other fields
    shutdown::Bool
end

# worker executes Request and returns a serialized Response object *if* Request has an id
struct Response
    result
    error::Union{Nothing, Exception}
    id::UInt64 # matches a corresponding Request.id
end

# simple Future that coordinator can wait on until a Response comes back for a Request
struct Future
    id::UInt64 # matches a corresponding Request.id
    value::Channel{Any} # size 1
end

Base.fetch(f::Future) = fetch(f.value)

mutable struct Worker
    lock::ReentrantLock # protects the .futures field; no other fields are modified after construction
    pid::Int
    process::Base.Process
    socket::TCPSocket
    messages::Task
    output::Task
    process_watch::Task
    futures::Dict{UInt64, Future} # Request.id -> Future
@static if VERSION < v"1.7"
    terminated::Threads.Atomic{Bool}
else
    @atomic terminated::Bool
end
end

isterminated(w::Worker) = @static VERSION < v"1.7" ? w.terminated[] : w.terminated

# used to close Future.value channels when a worker terminates
struct WorkerTerminatedException <: Exception
    worker::Worker
end

# performs all the "closing" tasks of worker fields
# but does not *wait* for a final close state
# so typically callers should call wait(w) after this
function terminate!(w::Worker, from::Symbol=:manual)
    @static if VERSION < v"1.7"
        already_terminated = Threads.atomic_xchg!(w.terminated, true)
    else
        already_terminated = @atomicswap :monotonic w.terminated = true
    end
    if !already_terminated
        @debug "terminating worker $(w.pid) from $from"
    end
    wte = WorkerTerminatedException(w)
    @lock w.lock begin
        for (_, fut) in w.futures
            close(fut.value, wte)
        end
        empty!(w.futures)
    end
    signal = Base.SIGTERM
    while true
        kill(w.process, signal)
        signal = signal == Base.SIGTERM ? Base.SIGINT : Base.SIGKILL
        process_exited(w.process) && break
        sleep(0.1)
        process_exited(w.process) && break
    end
    if !(w.socket.status == Base.StatusUninit || w.socket.status == Base.StatusInit || w.socket.handle === C_NULL)
        close(w.socket)
    end
    return
end

# Base.Process has a nifty .exitnotify Condition
# so we might as well get notified when the process exits
# as one of our ways of detecting the worker has gone away
function watch_and_terminate!(w::Worker)
    wait(w.process)
    terminate!(w, :watch_and_terminate)
    true
end

# gracefully terminate a worker by sending a shutdown message
# and waiting for the other tasks to perform worker shutdown
function Base.close(w::Worker)
    if !isterminated(w) && isopen(w.socket)
        req = Request(Symbol(), :(), rand(UInt64), true)
        @lock w.lock begin
            serialize(w.socket, req)
            flush(w.socket)
        end
    end
    wait(w)
    return
end

# wait until our spawned tasks have all finished
Base.wait(w::Worker) = fetch(w.process_watch) && fetch(w.messages) && fetch(w.output)

Base.show(io::IO, w::Worker) = print(io, "Worker(pid=$(w.pid)", isterminated(w) ? ", terminated=true, termsignal=$(w.process.termsignal)" : "", ")")

# used in testing to ensure all created workers are
# eventually cleaned up properly
const GLOBAL_CALLBACK_PER_WORKER = Ref{Any}()

function Worker(;
    env::AbstractDict=ENV,
    dir::String=pwd(),
    threads::String="auto",
    exeflags=`--threads=$threads`,
    connect_timeout::Int=60,
    worker_redirect_io::IO=stdout,
    worker_redirect_fn=(io, pid, line)->println(io, "  Worker $pid:  $line")
)
    # below copied from Distributed.launch
    env = Dict{String, String}(env)
    pathsep = Sys.iswindows() ? ";" : ":"
    if get(env, "JULIA_LOAD_PATH", nothing) === nothing
        env["JULIA_LOAD_PATH"] = join(LOAD_PATH, pathsep)
    end
    if get(env, "JULIA_DEPOT_PATH", nothing) === nothing
        env["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, pathsep)
    end
    # Set the active project on workers using JULIA_PROJECT.
    # Users can opt-out of this by (i) passing `env = ...` or (ii) passing
    # `--project=...` as `exeflags` to addprocs(...).
    project = Base.ACTIVE_PROJECT[]
    if project !== nothing && get(env, "JULIA_PROJECT", nothing) === nothing
        env["JULIA_PROJECT"] = project
    end
    # end copied from Distributed.launch
    ## start the worker process
    cmd = `$(Base.julia_cmd()) $exeflags --startup-file=no -e 'using ReTestItems; ReTestItems.Workers.startworker()'`
    proc = open(detach(setenv(addenv(cmd, env), dir=dir)), "r+")
    pid = Libc.getpid(proc)

    ## connect to the worker process with timeout
    try
        sock = try_with_timeout(connect_timeout) do
            port_str = ""
            while isempty(port_str) && !contains(port_str, r"juliaworker:\d+")
                port_str = readline(proc) # 1st thing the worker sends is port its listening on
            end
            # parse the port # and connect to the server
            return Sockets.connect(parse(Int, split(port_str, ':')[2]))
        end
        # create worker
        terminated = @static VERSION < v"1.7" ? Threads.Atomic{Bool}(false) : false
        w = Worker(ReentrantLock(), pid, proc, sock, Task(nothing), Task(nothing), Task(nothing), Dict{UInt64, Future}(), terminated)
        ## start a task to watch for worker process termination
        w.process_watch = Threads.@spawn watch_and_terminate!(w)
        ## start a task to redirect worker output
        w.output = Threads.@spawn redirect_worker_output(worker_redirect_io, w, worker_redirect_fn, proc)
        ## start a task to listen for worker messages
        w.messages = Threads.@spawn process_responses(w)
        # add a finalizer
        finalizer(x -> terminate!(x, :finalizer), w)
        if isassigned(GLOBAL_CALLBACK_PER_WORKER)
            GLOBAL_CALLBACK_PER_WORKER[](w)
        end
        return w
    catch
        # cleanup in case connect fails/times out
        kill(proc, Base.SIGKILL)
        @isdefined(sock) && close(sock)
        @isdefined(w) && terminate!(w, :Worker_catch)
        rethrow()
    end
end

function redirect_worker_output(io::IO, w::Worker, fn, proc)
    try
        while !process_exited(proc) && !isterminated(w)
            line = readline(proc)
            if !isempty(line)
                fn(io, w.pid, line)
                flush(io)
            end
        end
    catch e
        # @error "Error redirecting worker output $(w.pid)" exception=(e, catch_backtrace())
        terminate!(w, :redirect_worker_output)
        e isa EOFError || e isa Base.IOError || rethrow()
    end
    true
end

function process_responses(w::Worker)
    lock = w.lock
    reqs = w.futures
    try
        while isopen(w.socket) && !isterminated(w)
            # get the next Response from the worker
            r = deserialize(w.socket)
            @assert r isa Response "Received invalid response from worker $(w.pid): $(r)"
            # println("Received response $(r) from worker $(w.pid)")
            @lock lock begin
                @assert haskey(reqs, r.id) "Received response for unknown request $(r.id) from worker $(w.pid)"
                # look up the Future for this request
                fut = pop!(reqs, r.id)
                @assert !isready(fut.value) "Received duplicate response for request $(r.id) from worker $(w.pid)"
                if r.error !== nothing
                    # this allows rethrowing the exception from the worker to the caller
                    close(fut.value, r.error)
                else
                    put!(fut.value, r.result)
                end
            end
        end
    catch e
        # @error "Error processing responses from worker $(w.pid)" exception=(e, catch_backtrace())
        terminate!(w, :process_responses)
        e isa EOFError || e isa Base.IOError || rethrow()
    end
    true
end

remote_eval(w::Worker, expr) = remote_eval(w, Main, expr.head == :block ? Expr(:toplevel, expr.args...) : expr)

function remote_eval(w::Worker, mod, expr)
    isterminated(w) && throw(WorkerTerminatedException(w))
    # we only send the Symbol module name to the worker
    req = Request(nameof(mod), expr, rand(UInt64), false)
    @lock w.lock begin
        serialize(w.socket, req)
        flush(w.socket)
        fut = Future(req.id, Channel(1))
        w.futures[req.id] = fut
        return fut
    end
end

# convenience call to eval and fetch in one step
remote_fetch(w::Worker, args...) = fetch(remote_eval(w, args...))

function startworker()
    # don't need stdin (copied from Distributed.start_worker)
    redirect_stdin(devnull)
    close(stdin)
    redirect_stderr(stdout) # redirect stderr so coordinator reads everything from stdout
    port, sock = listenany(UInt16(rand(10000:50000)))
    # send the port to the coordinator
    println(stdout, "juliaworker:$port")
    flush(stdout)
    # copied from Distributed.start_worker
    Sockets.nagle(sock, false)
    Sockets.quickack(sock, true)
    try
        #TODO: spawn on interactive threadpool?
        serve_requests(accept(sock))
    finally
        close(sock)
        exit(0)
    end
end

# we need to lookup the module to eval in for this request
# so we loop through loaded modules until we find it
function getmodule(nm::Symbol)
    # fast-path Main/Base/Core
    nm == :Main && return Main
    nm == :Base && return Base
    nm == :Core && return Core
    for mod in Base.loaded_modules_array()
        if nameof(mod) == nm
            return mod
        end
    end
    error("module $nm not found")
end

function execute(r::Request)
    # @show r.mod, r.expr
    return Core.eval(getmodule(r.mod), r.expr)
end

function serve_requests(io)
    iolock = ReentrantLock()
    while true
        req = deserialize(io)
        @assert req isa Request
        req.shutdown && break
        # println("received request: $(req)")
        Threads.@spawn begin
            r = $req
            local resp
            try
                result = execute(r)
                resp = Response(result, nothing, r.id)
            catch e
                resp = Response(nothing, CapturedException(e, catch_backtrace()), r.id)
            finally
                @lock iolock begin
                    # println("sending response: $(resp)")
                    serialize(io, resp)
                    flush(io)
                end
            end
        end
        yield()
    end
end

end # module Workers
