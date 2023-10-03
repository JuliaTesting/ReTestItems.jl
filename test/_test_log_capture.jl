# This file defines tests that are run (under various configurations) by `test/log_capture.jl`.
using ReTestItems, Test, Logging, IOCapture
const log_display = Symbol(ENV["RETESTITEMS_LOGS"])

@testset "log capture logs=$(repr(log_display))" begin
    @testset "TestItem" begin
        @testset "log capture for println" begin
            ti = @testitem "uses println" _run=false begin
                println("println msg")
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test logs == "println msg\n"
        end

        @testset "log capture for println(stderr, ...)" begin
            ti = @testitem "uses println" _run=false begin
                println(stderr, "println msg")
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test logs == "println msg\n"
        end

        @testset "log capture for printstyled" begin
            ti = @testitem "uses printstyled" _run=false begin
                printstyled("printstyled msg red", color=:red)
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test logs == "\e[31mprintstyled msg red\e[39m"
        end

        @testset "log capture for @error" begin
            ti = @testitem "uses @error" _run=false begin
                @error("@error msg")
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test startswith(logs, "\e[91m\e[1m┌ \e[22m\e[39m\e[91m\e[1mError: \e[22m\e[39m@error msg\n\e[91m\e[1m└ \e[22m\e[39m\e[90m@ ")
        end

        @testset "@test_logs @info works within log capture" begin
            ti = @testitem "uses @test_logs @info" _run=false begin
                @test_logs (:info, "Look ma, I'm logging") begin
                    @info "Look ma, I'm logging"
                end
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test isempty(logs)
        end

        @testset "@test_logs @error works within log capture" begin
            ti = @testitem "uses @test_logs @error" _run=false begin
                @test_logs (:error, "Look ma, I'm logging") begin
                    @error "Look ma, I'm logging"
                end
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test isempty(logs)
        end

        @testset "redirect_stdout works within log capture" begin
            ti = @testitem "uses redirect_stdout" _run=false begin
                mktemp() do tmp_path, tmp_io
                    redirect_stdout(tmp_io) do
                        print("This should not be visible to log capture")
                    end
                    flush(tmp_io)
                    @test read(tmp_path, String) == "This should not be visible to log capture"
                end
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test isempty(logs)
        end

        @testset "redirect_stderr works within log capture" begin
            ti = @testitem "uses redirect_stderr" _run=false begin
                mktemp() do tmp_path, tmp_io
                    redirect_stderr(tmp_io) do
                        print(stderr, "This should not be visible to log capture")
                    end
                    flush(tmp_io)
                    @test read(tmp_path, String) == "This should not be visible to log capture"
                end
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test isempty(logs)
        end

        @testset "with_logger works within log capture (redirect to a file)" begin
            ti = @testitem "uses with_logger (redirect to a file)" _run=false begin
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
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test isempty(logs)
        end

        @testset "with_logger works within log capture" begin
            ti = @testitem "uses with_logger" _run=false begin
                using Logging
                logger = SimpleLogger()
                with_logger(logger) do
                    @info "This should be visible to log capture"
                end
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            @test startswith(logs, "┌ Info: This should be visible to log capture\n└ @ ")
        end

        @testset "log capture for display" begin
            ti = @testitem "uses display" _run=false begin
                display("display msg")
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(ti, 1), String)
            end
            # Displays use their own reference to stdout
            @test logs == "display msg" broken=true
        end
    end
    @testset "TestSetup" begin
        @testset "log capture for println" begin
            setup = @testsetup module LoggingTestSetup
                println("println msg")
            end
            ti = @testitem "setup uses println" setup=[LoggingTestSetup] _run=false begin end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
            @test logs == "println msg\n"
        end

        @testset "log capture for println(stderr, ...)" begin
            setup = @testsetup module LoggingTestSetup
                println(stderr, "println msg")
            end
            ti = @testitem "setup uses println" setup=[LoggingTestSetup] _run=false begin end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
            @test logs == "println msg\n"
        end


        @testset "log capture for printstyled" begin
            setup = @testsetup module LoggingTestSetup
                printstyled("printstyled msg red", color=:red)
            end
            ti = @testitem "setup uses printstyled" setup=[LoggingTestSetup] _run=false begin end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
            @test logs == "\e[31mprintstyled msg red\e[39m"
        end

        @testset "log capture for @error" begin
            setup = @testsetup module LoggingTestSetup
                @error("@error msg")
            end
            ti = @testitem "setup uses @error" setup=[LoggingTestSetup] _run=false begin end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
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
            ti = @testitem "setup uses redirect_stdout" setup=[LoggingTestSetup] _run=false begin
                tmp_path = LoggingTestSetup.tmp_path
                @test read(tmp_path, String) == "This should not be visible to log capture"
            end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
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
            ti = @testitem "setup uses redirect_stderr" setup=[LoggingTestSetup] _run=false begin
                tmp_path = LoggingTestSetup.tmp_path
                @test read(tmp_path, String) == "This should not be visible to log capture"
            end
            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
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
            ti = @testitem "setup uses with_logger (redirect to a file)" setup=[LoggingTestSetup] _run=false begin
                tmp_path = LoggingTestSetup.tmp_path
                @test startswith(read(tmp_path, String), "┌ Info: This should not be visible to log capture\n└ @ ")
            end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
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
            ti = @testitem "setup uses with_logger" setup=[LoggingTestSetup] _run=false begin end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
            @test startswith(logs, "┌ Info: This should be visible to log capture\n└ @ ")
        end

        @testset "log capture for display" begin
            setup = @testsetup module LoggingTestSetup
            display("display msg")
            end
            ti = @testitem "setup uses display" setup=[LoggingTestSetup] _run=false begin end

            if log_display == :eager
                logs = IOCapture.capture(()->ReTestItems.runtestitem(ti; logs=log_display), color=true).output
            else
                ReTestItems.runtestitem(ti; logs=log_display)
                logs = read(ReTestItems.logpath(setup), String)
            end
            # Displays use their own reference to stdout
            @test logs == "display msg" broken=true
        end
    end
end
