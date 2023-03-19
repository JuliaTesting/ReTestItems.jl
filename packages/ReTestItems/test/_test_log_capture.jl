using ReTestItems, Distributed, Test, Logging

@testset "log capture nthreads=$(Threads.nthreads()) nprocs=$(Distributed.nprocs())" begin
    @testset "TestItem" begin
        @testset "log capture for println" begin
            ti = @testitem "uses println" begin
                println("println msg")
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            @test logs == "println msg\n"
        end

        @testset "log capture for println(stderr, ...)" begin
            ti = @testitem "uses println" begin
                println(stderr, "println msg")
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            @test logs == "println msg\n"
        end

        @testset "log capture for printstyled" begin
            ti = @testitem "uses printstyled" begin
                printstyled("printstyled msg red", color=:red)
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            @test logs == "\e[31mprintstyled msg red\e[39m"
        end

        @testset "log capture for @error" begin
            ti = @testitem "uses @error" begin
                @error("@error msg")
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            @test startswith(logs, "\e[91m\e[1m┌ \e[22m\e[39m\e[91m\e[1mError: \e[22m\e[39m@error msg\n\e[91m\e[1m└ \e[22m\e[39m\e[90m@ ")
        end

        @testset "@test_logs @info works within log capture" begin
            ti = @testitem "uses @test_logs @info" begin
                @test_logs (:info, "Look ma, I'm logging") begin
                    @info "Look ma, I'm logging"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            @test isempty(logs)
        end

        @testset "@test_logs @error works within log capture" begin
            ti = @testitem "uses @test_logs @error" begin
                @test_logs (:error, "Look ma, I'm logging") begin
                    @error "Look ma, I'm logging"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
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
            logs = read(ReTestItems.logpath(ti), String)
            @test isempty(logs)
        end

        @testset "redirect_stderr works within log capture" begin
            ti = @testitem "uses redirect_stderr" begin
                mktemp() do tmp_path, tmp_io
                    redirect_stderr(tmp_io) do
                        print(stderr, "This should not be visible to log capture")
                    end
                    flush(tmp_io)
                    @test read(tmp_path, String) == "This should not be visible to log capture"
                end
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
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
            logs = read(ReTestItems.logpath(ti), String)
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
            logs = read(ReTestItems.logpath(ti), String)
            @test startswith(logs, "┌ Info: This should be visible to log capture\n└ @ ")
        end

        @testset "log capture for display" begin
            ti = @testitem "uses display" begin
                display("display msg")
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(ti), String)
            # Displays use their own reference to stdout
            @test logs == "display msg" broken=true
        end
    end
    @testset "TestSetup" begin
        @testset "log capture for println" begin
            setup = @testsetup module LoggingTestSetup
                println("println msg")
            end
            ti = @testitem "setup uses println" setup=[LoggingTestSetup] begin end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test logs == "println msg\n"
        end

        @testset "log capture for println(stderr, ...)" begin
            setup = @testsetup module LoggingTestSetup
                println(stderr, "println msg")
            end
            ti = @testitem "setup uses println" setup=[LoggingTestSetup] begin end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test logs == "println msg\n"
        end


        @testset "log capture for printstyled" begin
            setup = @testsetup module LoggingTestSetup
                printstyled("printstyled msg red", color=:red)
            end
            ti = @testitem "setup uses printstyled" setup=[LoggingTestSetup] begin end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test logs == "\e[31mprintstyled msg red\e[39m"
        end

        @testset "log capture for @error" begin
            setup = @testsetup module LoggingTestSetup
                @error("@error msg")
            end
            ti = @testitem "setup uses @error" setup=[LoggingTestSetup] begin end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test startswith(logs, "\e[91m\e[1m┌ \e[22m\e[39m\e[91m\e[1mError: \e[22m\e[39m@error msg\n\e[91m\e[1m└ \e[22m\e[39m\e[90m@ ")
        end

        @testset "redirect_stdout works within log capture" begin
            setup = @testsetup module LoggingTestSetup
                tmp_path, tmp_io = mktemp()
                redirect_stdout(tmp_io) do
                    print("This should not be visible to log capture")
                end
                flush(tmp_io)
            end
            ti = @testitem "setup uses redirect_stdout" setup=[LoggingTestSetup] begin
                tmp_path = LoggingTestSetup.tmp_path
                @test read(tmp_path, String) == "This should not be visible to log capture"
            end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test isempty(logs)
        end

        @testset "redirect_stderr works within log capture" begin
            setup = @testsetup module LoggingTestSetup
                tmp_path, tmp_io = mktemp()
                redirect_stderr(tmp_io) do
                    print(stderr, "This should not be visible to log capture")
                end
                flush(tmp_io)
            end
            ti = @testitem "setup uses redirect_stderr" setup=[LoggingTestSetup] begin
                tmp_path = LoggingTestSetup.tmp_path
                @test read(tmp_path, String) == "This should not be visible to log capture"
            end
            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test isempty(logs)
        end

        @testset "with_logger works within log capture (redirect to a file)" begin
            setup = @testsetup module LoggingTestSetup
                using Logging
                tmp_path, tmp_io = mktemp()
                logger = SimpleLogger(tmp_io)
                with_logger(logger) do
                    @info "This should not be visible to log capture"
                end
                flush(tmp_io)
            end
            ti = @testitem "setup uses with_logger (redirect to a file)" setup=[LoggingTestSetup] begin
                tmp_path = LoggingTestSetup.tmp_path
                @test startswith(read(tmp_path, String), "┌ Info: This should not be visible to log capture\n└ @ ")
            end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test isempty(logs)
        end

        @testset "with_logger works within log capture" begin
            setup = @testsetup module LoggingTestSetup
                using Logging
                logger = SimpleLogger()
                with_logger(logger) do
                    @info "This should be visible to log capture"
                end
            end
            ti = @testitem "setup uses with_logger" setup=[LoggingTestSetup] begin end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            @test startswith(logs, "┌ Info: This should be visible to log capture\n└ @ ")
        end

        @testset "log capture for display" begin
            setup = @testsetup module LoggingTestSetup
            display("display msg")
            end
            ti = @testitem "setup uses display" setup=[LoggingTestSetup] begin end

            ReTestItems.runtestitem(ti)
            logs = read(ReTestItems.logpath(setup), String)
            # Displays use their own reference to stdout
            @test logs == "display msg" broken=true
        end
    end
end
