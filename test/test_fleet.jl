@testset "Fleet Tests" begin

    #==========================================================================#
    # NodeConfig Tests
    #==========================================================================#
    @testset "NodeConfig" begin
        @testset "Basic construction" begin
            config = REPE.NodeConfig("localhost", 8080)
            @test config.name == "localhost"
            @test config.host == "localhost"
            @test config.port == 8080
            @test config.tags == String[]
            @test config.timeout == 30.0
        end

        @testset "Custom name" begin
            config = REPE.NodeConfig("192.168.1.10", 8080; name="compute-1")
            @test config.name == "compute-1"
            @test config.host == "192.168.1.10"
        end

        @testset "With tags" begin
            config = REPE.NodeConfig("localhost", 8080; tags=["compute", "gpu"])
            @test config.tags == ["compute", "gpu"]
        end

        @testset "Custom timeout" begin
            config = REPE.NodeConfig("localhost", 8080; timeout=60.0)
            @test config.timeout == 60.0
        end

        @testset "Invalid port" begin
            @test_throws ArgumentError REPE.NodeConfig("localhost", 0)
            @test_throws ArgumentError REPE.NodeConfig("localhost", 70000)
        end

        @testset "Invalid timeout" begin
            @test_throws ArgumentError REPE.NodeConfig("localhost", 8080; timeout=0.0)
            @test_throws ArgumentError REPE.NodeConfig("localhost", 8080; timeout=-1.0)
        end
    end

    #==========================================================================#
    # Fleet Construction Tests
    #==========================================================================#
    @testset "Fleet Construction" begin
        @testset "Empty fleet" begin
            fleet = REPE.Fleet()
            @test length(fleet) == 0
        end

        @testset "Fleet from configs" begin
            configs = [
                REPE.NodeConfig("localhost", 9101; name="node-1"),
                REPE.NodeConfig("localhost", 9102; name="node-2"),
            ]
            fleet = REPE.Fleet(configs)
            @test length(fleet) == 2
        end

        @testset "Duplicate names throw error" begin
            configs = [
                REPE.NodeConfig("localhost", 9101),
                REPE.NodeConfig("localhost", 9102),  # Same name (defaults to host)
            ]
            @test_throws ArgumentError REPE.Fleet(configs)
        end

        @testset "Duplicate names - explicit" begin
            configs = [
                REPE.NodeConfig("host1", 9101; name="same-name"),
                REPE.NodeConfig("host2", 9102; name="same-name"),
            ]
            @test_throws ArgumentError REPE.Fleet(configs)
        end

        @testset "Constructor parameters" begin
            configs = [REPE.NodeConfig("localhost", 9101; name="node-1")]
            fleet = REPE.Fleet(configs; timeout=60.0, max_retry_attempts=5, retry_delay=2.0)
            @test fleet.default_timeout == 60.0
            @test fleet.retry_policy.max_attempts == 5
            @test fleet.retry_policy.delay == 2.0
        end

        @testset "Invalid constructor parameters" begin
            configs = [REPE.NodeConfig("localhost", 9101; name="node-1")]
            @test_throws ArgumentError REPE.Fleet(configs; timeout=0.0)
            @test_throws ArgumentError REPE.Fleet(configs; max_retry_attempts=0)
            @test_throws ArgumentError REPE.Fleet(configs; retry_delay=-1.0)
        end
    end

    #==========================================================================#
    # Node Access Tests
    #==========================================================================#
    @testset "Node Access" begin
        configs = [
            REPE.NodeConfig("localhost", 9101; name="node-1", tags=["compute", "primary"]),
            REPE.NodeConfig("localhost", 9102; name="node-2", tags=["compute"]),
            REPE.NodeConfig("localhost", 9103; name="node-3", tags=["storage"]),
        ]
        fleet = REPE.Fleet(configs)

        @testset "nodes()" begin
            all_nodes = REPE.nodes(fleet)
            @test length(all_nodes) == 3
            @test all(n -> n isa REPE.Node, all_nodes)
        end

        @testset "getindex" begin
            node = fleet["node-1"]
            @test node.name == "node-1"
            @test node.port == 9101
        end

        @testset "getindex - not found" begin
            @test_throws KeyError fleet["nonexistent"]
        end

        @testset "keys()" begin
            k = keys(fleet)
            @test length(k) == 3
            @test "node-1" in k
            @test "node-2" in k
            @test "node-3" in k
        end

        @testset "filter_nodes by tags" begin
            compute_nodes = REPE.filter_nodes(fleet; tags=["compute"])
            @test length(compute_nodes) == 2
            @test all(n -> "compute" in n.tags, compute_nodes)

            storage_nodes = REPE.filter_nodes(fleet; tags=["storage"])
            @test length(storage_nodes) == 1
            @test storage_nodes[1].name == "node-3"

            primary_nodes = REPE.filter_nodes(fleet; tags=["compute", "primary"])
            @test length(primary_nodes) == 1
            @test primary_nodes[1].name == "node-1"

            # Empty result
            no_nodes = REPE.filter_nodes(fleet; tags=["nonexistent"])
            @test length(no_nodes) == 0
        end
    end

    #==========================================================================#
    # Dynamic Node Management Tests
    #==========================================================================#
    @testset "Dynamic Node Management" begin
        @testset "add_node!" begin
            fleet = REPE.Fleet()
            @test length(fleet) == 0

            REPE.add_node!(fleet, REPE.NodeConfig("localhost", 9101; name="node-1"))
            @test length(fleet) == 1
            @test "node-1" in keys(fleet)

            REPE.add_node!(fleet, REPE.NodeConfig("localhost", 9102; name="node-2"))
            @test length(fleet) == 2
        end

        @testset "add_node! duplicate throws" begin
            fleet = REPE.Fleet()
            REPE.add_node!(fleet, REPE.NodeConfig("localhost", 9101; name="node-1"))
            @test_throws ArgumentError REPE.add_node!(fleet, REPE.NodeConfig("localhost", 9102; name="node-1"))
        end

        @testset "remove_node!" begin
            configs = [
                REPE.NodeConfig("localhost", 9101; name="node-1"),
                REPE.NodeConfig("localhost", 9102; name="node-2"),
            ]
            fleet = REPE.Fleet(configs)
            @test length(fleet) == 2

            REPE.remove_node!(fleet, "node-1")
            @test length(fleet) == 1
            @test !("node-1" in keys(fleet))
            @test "node-2" in keys(fleet)
        end

        @testset "remove_node! nonexistent is no-op" begin
            fleet = REPE.Fleet()
            REPE.remove_node!(fleet, "nonexistent")  # Should not throw
            @test length(fleet) == 0
        end
    end

    #==========================================================================#
    # RemoteResult Tests
    #==========================================================================#
    @testset "RemoteResult" begin
        @testset "Success result" begin
            result = REPE.RemoteResult{Dict}("node-1", Dict("value" => 42), nothing, 0.1)
            @test REPE.succeeded(result)
            @test !REPE.failed(result)
            @test result[] == Dict("value" => 42)
            @test result.node == "node-1"
            @test result.elapsed == 0.1
        end

        @testset "Failed result" begin
            err = ErrorException("Connection failed")
            result = REPE.RemoteResult{Dict}("node-1", nothing, err, 0.5)
            @test !REPE.succeeded(result)
            @test REPE.failed(result)
            @test_throws ErrorException result[]
        end
    end

    #==========================================================================#
    # Connection Management Tests (with real servers)
    #==========================================================================#
    @testset "Connection Management" begin
        # Start test servers
        port1 = 9201
        port2 = 9202
        port3 = 9203

        server1 = REPE.Server("localhost", port1)
        server2 = REPE.Server("localhost", port2)

        REPE.register(server1, "/status", (params, req) -> Dict("status" => "ok", "node" => 1))
        REPE.register(server2, "/status", (params, req) -> Dict("status" => "ok", "node" => 2))

        REPE.listen(server1; async=true)
        REPE.listen(server2; async=true)
        REPE.wait_for_server("localhost", port1)
        REPE.wait_for_server("localhost", port2)

        try
            configs = [
                REPE.NodeConfig("localhost", port1; name="server-1"),
                REPE.NodeConfig("localhost", port2; name="server-2"),
                REPE.NodeConfig("localhost", port3; name="server-3"),  # Not running
            ]
            fleet = REPE.Fleet(configs)

            @testset "connect!" begin
                result = REPE.connect!(fleet)
                @test "server-1" in result.connected
                @test "server-2" in result.connected
                @test "server-3" in result.failed
            end

            @testset "isconnected variants" begin
                @test !REPE.isconnected(fleet)  # Not all connected (server-3 failed)
                @test REPE.isconnected(fleet, "server-1")
                @test REPE.isconnected(fleet, "server-2")
                @test !REPE.isconnected(fleet, "server-3")

                node1 = fleet["server-1"]
                @test REPE.isconnected(node1)
            end

            @testset "connected_nodes" begin
                connected = REPE.connected_nodes(fleet)
                @test length(connected) == 2
                names = [n.name for n in connected]
                @test "server-1" in names
                @test "server-2" in names
            end

            @testset "disconnect!" begin
                result = REPE.disconnect!(fleet)
                @test "server-1" in result.disconnected
                @test "server-2" in result.disconnected
                @test !REPE.isconnected(fleet, "server-1")
                @test !REPE.isconnected(fleet, "server-2")
            end

            @testset "reconnect!" begin
                # Reconnect to the servers that were disconnected
                result = REPE.reconnect!(fleet)
                @test "server-1" in result.reconnected
                @test "server-2" in result.reconnected
                @test REPE.isconnected(fleet, "server-1")
                @test REPE.isconnected(fleet, "server-2")
            end

        finally
            REPE.stop(server1)
            REPE.stop(server2)
        end
    end

    #==========================================================================#
    # Remote Invocation Tests
    #==========================================================================#
    @testset "Remote Invocation" begin
        port1 = 9301
        port2 = 9302

        server1 = REPE.Server("localhost", port1)
        server2 = REPE.Server("localhost", port2)

        REPE.register(server1, "/compute", (params, req) -> Dict("result" => params["value"] * 2, "node" => 1))
        REPE.register(server2, "/compute", (params, req) -> Dict("result" => params["value"] * 3, "node" => 2))
        REPE.register(server1, "/status", (params, req) -> Dict("status" => "ok"))
        REPE.register(server2, "/status", (params, req) -> Dict("status" => "ok"))

        REPE.listen(server1; async=true)
        REPE.listen(server2; async=true)
        REPE.wait_for_server("localhost", port1)
        REPE.wait_for_server("localhost", port2)

        try
            configs = [
                REPE.NodeConfig("localhost", port1; name="server-1", tags=["compute"]),
                REPE.NodeConfig("localhost", port2; name="server-2", tags=["compute", "primary"]),
            ]
            fleet = REPE.Fleet(configs)
            REPE.connect!(fleet)

            @testset "call" begin
                result = REPE.call(fleet, "server-1", "/compute", Dict("value" => 10))
                @test REPE.succeeded(result)
                @test result.value["result"] == 20
                @test result.node == "server-1"

                result2 = REPE.call(fleet, "server-2", "/compute", Dict("value" => 10))
                @test REPE.succeeded(result2)
                @test result2.value["result"] == 30
            end

            @testset "call - node not found" begin
                @test_throws KeyError REPE.call(fleet, "nonexistent", "/status", nothing)
            end

            @testset "broadcast" begin
                results = REPE.broadcast(fleet, "/status")
                @test length(results) == 2
                @test haskey(results, "server-1")
                @test haskey(results, "server-2")
                @test all(REPE.succeeded, values(results))
            end

            @testset "broadcast with tags" begin
                results = REPE.broadcast(fleet, "/status"; tags=["primary"])
                @test length(results) == 1
                @test haskey(results, "server-2")

                results_compute = REPE.broadcast(fleet, "/compute", Dict("value" => 5); tags=["compute"])
                @test length(results_compute) == 2
            end

            @testset "map_reduce" begin
                total = REPE.map_reduce(fleet, "/compute", Dict("value" => 10); tags=["compute"]) do results
                    sum(r.value["result"] for r in results if REPE.succeeded(r))
                end
                @test total == 50  # 20 + 30
            end

            @testset "callable syntax - broadcast" begin
                results = fleet("/status")
                @test length(results) == 2
                @test all(REPE.succeeded, values(results))
            end

            @testset "callable syntax - single node" begin
                result = fleet("server-1", "/compute", Dict("value" => 7))
                @test REPE.succeeded(result)
                @test result.value["result"] == 14
            end

        finally
            REPE.stop(server1)
            REPE.stop(server2)
        end
    end

    #==========================================================================#
    # Health Check Tests
    #==========================================================================#
    @testset "Health Check" begin
        port1 = 9401
        port2 = 9402

        server1 = REPE.Server("localhost", port1)
        REPE.register(server1, "/status", (params, req) -> Dict("status" => "healthy"))
        REPE.listen(server1; async=true)
        REPE.wait_for_server("localhost", port1)

        try
            configs = [
                REPE.NodeConfig("localhost", port1; name="healthy-server"),
                REPE.NodeConfig("localhost", port2; name="dead-server"),  # Not running
            ]
            fleet = REPE.Fleet(configs)

            health = REPE.health_check(fleet)

            @test haskey(health, "healthy-server")
            @test haskey(health, "dead-server")

            @test health["healthy-server"].healthy == true
            @test health["healthy-server"].error === nothing
            @test health["healthy-server"].latency > 0

            @test health["dead-server"].healthy == false
            @test health["dead-server"].error !== nothing

        finally
            REPE.stop(server1)
        end
    end

    #==========================================================================#
    # Retry Logic Tests
    #==========================================================================#
    @testset "Retry Logic" begin
        port = 9501

        # Server that fails first 2 requests then succeeds
        call_count = Ref(0)
        server = REPE.Server("localhost", port)
        REPE.register(server, "/flaky", function(params, req)
            call_count[] += 1
            if call_count[] < 3
                throw(ErrorException("Temporary failure"))
            end
            return Dict("success" => true, "attempt" => call_count[])
        end)

        REPE.listen(server; async=true)
        REPE.wait_for_server("localhost", port)

        try
            configs = [REPE.NodeConfig("localhost", port; name="flaky-server")]
            fleet = REPE.Fleet(configs; max_retry_attempts=5, retry_delay=0.1)
            REPE.connect!(fleet)

            # Should eventually succeed after retries
            result = REPE.call(fleet, "flaky-server", "/flaky", nothing)
            @test REPE.succeeded(result)
            @test result.value["success"] == true

        finally
            REPE.stop(server)
        end
    end

    #==========================================================================#
    # Thread Safety Tests
    #==========================================================================#
    @testset "Thread Safety" begin
        port = 9601

        server = REPE.Server("localhost", port)
        REPE.register(server, "/echo", (params, req) -> params)
        REPE.listen(server; async=true)
        REPE.wait_for_server("localhost", port)

        try
            configs = [REPE.NodeConfig("localhost", port; name="server-1")]
            fleet = REPE.Fleet(configs)
            REPE.connect!(fleet)

            # Concurrent broadcasts
            tasks = Task[]
            for i in 1:10
                push!(tasks, @async begin
                    REPE.broadcast(fleet, "/echo", Dict("id" => i))
                end)
            end

            results = [fetch(t) for t in tasks]
            @test length(results) == 10
            @test all(r -> length(r) == 1, results)

        finally
            REPE.stop(server)
        end
    end

    #==========================================================================#
    # Pretty Printing Tests
    #==========================================================================#
    @testset "Pretty Printing" begin
        config = REPE.NodeConfig("localhost", 8080; name="test-node", tags=["compute"])
        @test occursin("NodeConfig", string(config))
        @test occursin("localhost", string(config))

        configs = [REPE.NodeConfig("localhost", 9701; name="node-1")]
        fleet = REPE.Fleet(configs)
        @test occursin("Fleet", string(fleet))

        result_success = REPE.RemoteResult{Any}("node-1", Dict(), nothing, 0.1)
        @test occursin("success", string(result_success))

        result_failed = REPE.RemoteResult{Any}("node-1", nothing, ErrorException("err"), 0.1)
        @test occursin("failed", string(result_failed))
    end

end
