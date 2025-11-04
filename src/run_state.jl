using TOML: TOML
using CRC32c: CRC32c
using Dates: Dates


const MAGIC = 0x78ab8eb8 # hash("ReTestItems.jl") % UInt32
const CURR_VERSION = UInt32(0)

@enum PROJECT_ID_KIND::UInt8 begin
    UUID = 1
    NAME = 2
    CRC32C = 3
end

function _parse_project_for_header(io)
    proj = TOML.parse(io)
    id = get(proj, "uuid", nothing)
    id_kind = UUID
    if id === nothing
        id = get(proj, "name", nothing)
        id_kind = NAME
    end
    if id === nothing
        id = get(proj, "crc32c", CRC32c.crc32c(seekstart(io)))
        id_kind = CRC32C
    end
    manifest = get(proj, "manifest", "")
    if manifest != ""
        manifest = dirname(manifest)
    else
        manifest = ""
    end
    return id, id_kind, manifest
end

struct RunStateFile
    io::IO
    path::String
    offset_to_statuses::UInt32
end

function init_run_state(path, testitems, projectfile, project_root, cfg::_Config)
    io = open(path, "w")

    ## Metadata
    write(io, MAGIC)        # 4 bytes
    write(io, CURR_VERSION) # 4 bytes
    write(io, UInt32(0))    # offset_to_statuses, will be filled later

    ## Run info
    write(io, UInt32(length(testitems.testitems))) # number of test items
    write(io, Dates.datetime2unix(Dates.now(Dates.UTC))) # 8 bytes, start time
    let pkgversion = string(pkgversion(ReTestItems))
        write(io, UInt32(ncodeunits(pkgversion)))
        write(io, pkgversion)
    end
    let juliaversion = string(VERSION)
        write(io, UInt32(ncodeunits(juliaversion)))
        write(io, juliaversion)
    end
    # commit_hash = chomp(read(`git rev-parse HEAD`, String)) # or use LibGit2
    # commit_hash = LibGit2.GitHash(LibGit2.peel(LibGit2.head(LibGit2.GitRepo("."))))
    # write(io, UInt32(ncodeunits(commit_hash)))
    # write(io, commit_hash)

    # Config
    write(io, UInt32(cfg.nworkers))
    write(io, UInt32(ncodeunits(cfg.nworker_threads)))
    write(io, cfg.nworker_threads)
    let init_str = string(cfg.worker_init_expr) # compress?
        write(io, UInt32(ncodeunits(init_str)))
        write(io, init_str)
    end
    let end_str = string(cfg.test_end_expr) # compress?
        write(io, UInt32(ncodeunits(end_str)))
        write(io, end_str)
    end
    write(io, UInt32(cfg.testitem_timeout))
    write(io, cfg.testitem_failfast) # bitflags for bools?
    write(io, cfg.failfast)
    write(io, UInt32(cfg.retries))
    let logs = string(cfg.logs) # unroll the three options?
        write(io, UInt32(ncodeunits(logs)))
        write(io, logs)
    end
    write(io, cfg.report)
    write(io, cfg.verbose_results)
    write(io, UInt32(cfg.timeout_profile_wait))
    write(io, Float32(cfg.memory_threshold))
    write(io, cfg.gc_between_testitems)
    write(io, cfg.failures_first)

    ## Project info
    protect_id, project_id_kind, manifest_field = open(_parse_project_for_header, projectfile)
    write(io, UInt32(project_id_kind) << 24 | UInt32(ncodeunits(protect_id))) # 4 bytes: length of id and kind in high byte
    write(io, protect_id)
    write(io, UInt32(ncodeunits(manifest_field))) # manifest or nothing
    write(io, manifest_field)
    # TODO: Manifest hash?

    ## Test items
    prev_path = ""
    for ti in testitems.testitems
        if ti.file != prev_path
            let file = nestedrelpath(ti.file, project_root)
                write(io, UInt32(0)) # sentinel for new path
                write(io, UInt32(ncodeunits(file)))
                write(io, file)
            end
            prev_path = ti.file
        end
        write(io, UInt32(ncodeunits(ti.name)))
        write(io, ti.name)
    end

    offset_to_statuses = position(io)
    seek(io, 8)
    write(io, UInt32(offset_to_statuses)) # offset_to_statuses
    seek(io, offset_to_statuses)

    ## Statuses
    for _ in 1:length(testitems.testitems)
        write(io, ((UInt32(_UNSEEN) << 28) | (0x0f000000 & (UInt32(0) << 24)) | UInt32(0))) # status 4bits, nretries 4bits, number 24bits
        write(io, Float32(0.0)) # running time
        write(io, Float32(0.0)) # compilation time
    end
    flush(io)
    seek(io, offset_to_statuses)

    return RunStateFile(io, path, offset_to_statuses)
end

const _STATE_LOCK = Threads.SpinLock()

function write_status(rsf::RunStateFile, ti::TestItem, run_number::Int, timeout::Union{Nothing, Int}, status::_TEST_STATUS)
    index = UInt32(ti.number[])
    seek(rsf.io, rsf.offset_to_statuses + (index - one(UInt32)) * (sizeof(UInt32) + 2*sizeof(Float32)))
    write(rsf.io, (((UInt32(status) << 28) | (0x0f000000 & (UInt32(run_number) << 24))) | index))
    if status in (_PASSED, _FAILED)
        stats = ti.stats[run_number]
        write(rsf.io, Float32(stats.elapsedtime/1e9))
        write(rsf.io, Float32(stats.compile_time/1e9))
    elseif status === _TIMEDOUT
        write(rsf.io, Float32(something(timeout, 0)))
        write(rsf.io, Float32(0.0))
    else
        write(rsf.io, Float32(0.0))
        write(rsf.io, Float32(0.0))
    end
    flush(rsf.io)
    return nothing
end

function write_status_locked(rsf::RunStateFile, ti::TestItem, run_number::Int, timeout::Union{Nothing, Int}, status::_TEST_STATUS)
    @lock _STATE_LOCK @inline write_status(rsf, ti, run_number, timeout, status)
    return nothing
end

function read_string_view(io, bytes)
    len = read(io, UInt32)
    pos = UInt32(position(io) + 1)
    skip(io, len) # move the cursor
    return StringView(@view(bytes[pos:pos+len-one(UInt32)]))
end
function read_string(io)
    len = read(io, UInt32)
    return String(read(io, len))
end


function read_string_view(io, bytes, len)
    pos = UInt32(position(io) + 1)
    skip(io, len) # move the cursor
    return StringView(@view(bytes[pos:pos+len-one(UInt32)]))
end

function read_run_state(path)
    bytes = read(path) # mmap? needs to be GC rooted for all the string views
    io = IOBuffer(bytes)

    magic = read(io, UInt32)
    magic != MAGIC && error("File $path is not a valid ReTestItems run state file")
    format_version = read(io, UInt32)
    format_version != CURR_VERSION && error("File $path has version $format_version, but this version of ReTestItems only supports version $CURR_VERSION")
    offset_to_statuses = read(io, UInt32)

    ntestitems = read(io, UInt32)
    start_time = Dates.unix2datetime(read(io, Float64))
    pkgversion = read_string_view(io, bytes)
    juliaversion = read_string_view(io, bytes)

    nworkers = read(io, UInt32)
    nworker_threads = read_string(io)
    worker_init_expr = Meta.parse(read_string(io))
    test_end_expr = Meta.parse(read_string(io))
    testitem_timeout = read(io, UInt32)
    testitem_failfast = read(io, Bool)
    failfast = read(io, Bool)
    retries = read(io, UInt32)
    logs = Symbol(read_string(io))
    report = read(io, Bool)
    verbose_results = read(io, Bool)
    timeout_profile_wait = read(io, UInt32)
    memory_threshold = Float64(read(io, Float32))
    gc_between_testitems = read(io, Bool)
    failures_first = read(io, Bool)

    cfg = _Config(nworkers, nworker_threads, worker_init_expr, test_end_expr, testitem_timeout, testitem_failfast, failfast, retries, logs, report, verbose_results, timeout_profile_wait, memory_threshold, gc_between_testitems, failures_first)

    project_id_info = read(io, UInt32)
    project_id_kind = Base.bitcast(PROJECT_ID_KIND, UInt8((project_id_info >> 24) & 0xff))
    project_id = read_string_view(io, bytes, project_id_info & 0x00ffffff)
    manifest_field = read_string_view(io, bytes)


    ntestitem_paths = Int(ntestitems)
    testitems = Vector{@NamedTuple{name::typeof(pkgversion), file::typeof(pkgversion)}}(undef, ntestitems)
    @assert read(io, UInt32) == 0
    path = read_string_view(io, bytes)
    while ntestitem_paths > 0
        len_or_sentinel = read(io, UInt32)
        if len_or_sentinel == 0
            path = read_string_view(io, bytes)
        else
            name = read_string_view(io, bytes, len_or_sentinel)
            ntestitem_paths -= 1
            testitems[ntestitems - ntestitem_paths] = (name=name, file=path)
        end
    end

    statuses = Vector{@NamedTuple{status::_TEST_STATUS, run::Int8, number::Int, elapsed::Float32, compile::Float32}}(undef, ntestitems)
    if ntestitems > 0
        # seek(io, offset_to_statuses)
        for i in 1:ntestitems
            status_info = read(io, UInt32)
            status = Base.bitcast(_TEST_STATUS, UInt8((status_info >> 28) & 0x0f))
            run = Int8((status_info >> 24) & 0x0f)
            number = Int(status_info & 0x00ffffff)
            elapsed = read(io, Float32)
            compile = read(io, Float32)
            statuses[i] = (status=status, run=run, number=number, elapsed=elapsed, compile=compile)
        end
    end
    return testitems, statuses, cfg, bytes
end
