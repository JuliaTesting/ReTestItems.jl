using ReTestItems, Distributed, Test, Logging

@testset "log capture nthreads=$(Threads.nthreads()) nprocs=$(Distributed.nprocs())" begin
    multithreaded_log_capture = Threads.nthreads() > 1 && Distributed.nprocs() == 1
    multithreaded_log_capture && ReTestItems._setup_multithreaded_log_capture()
    try
        @testset "log capture for println" begin
            ti = @testitem "uses println" begin
                println("println msg")
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test logs == "println msg\n"
        end

        @testset "log capture for printstyled" begin
            ti = @testitem "uses printstyled" begin
                printstyled("printstyled msg red", color=:red)
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test logs == "\e[31mprintstyled msg red\e[39m"
        end

        @testset "log capture for @error" begin
            ti = @testitem "uses @error" begin
                @error("@error msg")
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test startswith(logs, "\e[91m\e[1m┌ \e[22m\e[39m\e[91m\e[1mError: \e[22m\e[39m@error msg\n\e[91m\e[1m└ \e[22m\e[39m\e[90m@ ")
        end

        @testset "@test_logs @info works within log capture" begin
            ti = @testitem "uses @test_logs @info" begin
                @test_logs (:info, "Look ma, I'm logging") begin
                    @info "Look ma, I'm logging"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test isempty(logs)
        end

        @testset "@test_logs @error works within log capture" begin
            ti = @testitem "uses @test_logs @error" begin
                @test_logs (:error, "Look ma, I'm logging") begin
                    @error "Look ma, I'm logging"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test isempty(logs)
        end

        @testset "redirect_stdout works within log capture" begin
            ti = @testitem "uses redirect_stdout" begin
                mktemp() do tmp_path, tmp_io
                    redirect_stdout(tmp_io) do
                        print("This should not be visible to log capture")
                    end
                    flush(tmp_io)
                    @test read(tmp_path, String) == "This should not be visible to log capture"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test isempty(logs)
        end

        @testset "with_logger works within log capture (redirect to a file)" begin
            ti = @testitem "uses with_logger (redirect to a file)" begin
                using Logging
               mktemp() do tmp_path, tmp_io
                    logger = SimpleLogger(tmp_io)
                    with_logger(logger) do
                        @info "This should not be visible to log capture"
                    end
                    flush(tmp_io)
                    @test startswith(read(tmp_path, String), "┌ Info: This should not be visible to log capture\n└ @ ")
                end
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            @test isempty(logs)
        end

        @testset "with_logger works within log capture" begin
            ti = @testitem "uses with_logger" begin
                using Logging
                logger = SimpleLogger()
                with_logger(logger) do
                    @info "This should be visible to log capture"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            # ContextVariablesX disappears when logstate changes so multithreded log capture is broken
            @test startswith(logs, "┌ Info: This should be visible to log capture\n└ @ ") broken=multithreaded_log_capture
        end

        @testset "log capture for display" begin
            ti = @testitem "uses display" begin
                display("display msg")
            end
            ReTestItems.runtestitem(ti)
            logs = String(take!(ti.logstore))
            # Displays use their own reference to stdout
            @test logs == "display msg" broken=true
        end
    finally
        multithreaded_log_capture && ReTestItems._teardown_multithreaded_log_capture()
    end
end
