using Test
using REPE
using Sockets

import REPE: listen, register

@testset "UniUDP Integration" begin

    @testset "UniUDPClient construction" begin
        client = UniUDPClient(ip"127.0.0.1", 9999; redundancy=2, fec_group_size=4)
        @test client.target_host == ip"127.0.0.1"
        @test client.target_port == 9999
        @test client.redundancy == 2
        @test client.fec_group_size == 4
        @test isopen(client)
        close(client)
        @test !isopen(client)
    end

    @testset "UniUDPServer construction" begin
        server = UniUDPServer(9998)
        @test isopen(server)
        @test !server.running[]
        close(server)
        @test !isopen(server)
    end

    @testset "Simple notification roundtrip" begin
        received = Channel{Any}(10)

        server = UniUDPServer(9997; inactivity_timeout=0.5, overall_timeout=5.0)

        register(server, "/test/echo") do params, msg
            put!(received, ("echo", params))
        end

        register(server, "/test/ping") do params, msg
            put!(received, ("ping", "pong"))
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9997; redundancy=4)

        # Send messages sequentially for predictable test ordering
        # (UniUDP handles concurrent messages, but each receive_message returns one)
        send_notify(client, "/test/echo", Dict("message" => "hello", "count" => 42))
        @test timedwait(() -> isready(received), 1.0) == :ok
        tag1, data1 = take!(received)

        send_notify(client, "/test/ping", nothing)
        @test timedwait(() -> isready(received), 1.0) == :ok
        tag2, data2 = take!(received)

        messages = Dict(tag1 => data1, tag2 => data2)

        @test haskey(messages, "echo")
        @test haskey(messages, "ping")
        @test messages["echo"]["message"] == "hello"
        @test messages["echo"]["count"] == 42
        @test messages["ping"] == "pong"

        close(client)
        close(server)
    end

    @testset "Request with response_callback" begin
        results = Channel{Any}(10)

        server = UniUDPServer(9996;
            inactivity_timeout=0.5,
            overall_timeout=5.0,
            response_callback = (method, result, msg) -> put!(results, (method, result))
        )

        register(server, "/compute/square") do params, msg
            return params["x"]^2
        end

        register(server, "/compute/double") do params, msg
            return params["value"] * 2
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9996; redundancy=4)

        # Send requests sequentially for predictable test ordering
        send_request(client, "/compute/square", Dict("x" => 7))
        @test timedwait(() -> isready(results), 1.0) == :ok
        method1, result1 = take!(results)

        send_request(client, "/compute/double", Dict("value" => 21))
        @test timedwait(() -> isready(results), 1.0) == :ok
        method2, result2 = take!(results)

        callback_results = Dict(method1 => result1, method2 => result2)

        @test haskey(callback_results, "/compute/square")
        @test haskey(callback_results, "/compute/double")
        @test callback_results["/compute/square"] == 49
        @test callback_results["/compute/double"] == 42

        close(client)
        close(server)
    end

    @testset "Notification ignores return value" begin
        callback_invoked = Ref(false)
        handler_done = Channel{Bool}(1)

        server = UniUDPServer(9995;
            inactivity_timeout=0.3,
            overall_timeout=2.0,
            response_callback = (method, result, msg) -> (callback_invoked[] = true)
        )

        register(server, "/test/notify_with_return") do params, msg
            put!(handler_done, true)
            return "this should be ignored"
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9995; redundancy=4)

        send_notify(client, "/test/notify_with_return", Dict("data" => 123))

        # Wait for handler to complete
        @test timedwait(() -> isready(handler_done), 1.0) == :ok
        take!(handler_done)

        # Give a moment for callback to potentially fire (it shouldn't)
        sleep(0.1)

        @test !callback_invoked[]

        close(client)
        close(server)
    end

    @testset "Large message" begin
        received = Channel{Any}(1)

        server = UniUDPServer(9994; inactivity_timeout=0.5, overall_timeout=5.0)

        register(server, "/test/large") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9994;
                              redundancy=4,
                              chunk_size=1024,
                              fec_group_size=4)

        large_data = Dict("data" => repeat("x", 5000), "id" => 12345)
        send_notify(client, "/test/large", large_data)

        @test timedwait(() -> isready(received), 2.0) == :ok
        result = take!(received)
        @test result["id"] == 12345
        @test length(result["data"]) == 5000

        close(client)
        close(server)
    end

    @testset "BEVE body format" begin
        received = Channel{Any}(1)

        server = UniUDPServer(9993; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/beve") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9993)

        send_notify(client, "/test/beve", Dict("value" => 3.14159, "name" => "pi");
                    body_format=REPE.BODY_BEVE)

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["name"] == "pi"
        @test isapprox(result["value"], 3.14159; atol=1e-5)

        close(client)
        close(server)
    end

    @testset "Multiple handlers" begin
        results = Dict{String, Any}()
        done = Channel{Bool}(3)

        server = UniUDPServer(9992; inactivity_timeout=0.2, overall_timeout=3.0)

        register(server, "/sensor/temp") do params, msg
            results["temp"] = params["value"]
            put!(done, true)
        end

        register(server, "/sensor/humidity") do params, msg
            results["humidity"] = params["value"]
            put!(done, true)
        end

        register(server, "/sensor/pressure") do params, msg
            results["pressure"] = params["value"]
            put!(done, true)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 9992)

        # Send sequentially for predictable test ordering
        send_notify(client, "/sensor/temp", Dict("value" => 23.5))
        @test timedwait(() -> isready(done), 1.0) == :ok
        take!(done)

        send_notify(client, "/sensor/humidity", Dict("value" => 65.0))
        @test timedwait(() -> isready(done), 1.0) == :ok
        take!(done)

        send_notify(client, "/sensor/pressure", Dict("value" => 1013.25))
        @test timedwait(() -> isready(done), 1.0) == :ok
        take!(done)

        @test results["temp"] == 23.5
        @test results["humidity"] == 65.0
        @test results["pressure"] == 1013.25

        close(client)
        close(server)
    end

    @testset "Pretty printing" begin
        client = UniUDPClient(ip"127.0.0.1", 8888; redundancy=5, fec_group_size=4)
        str = string(client)
        @test contains(str, "127.0.0.1")
        @test contains(str, "8888")
        @test contains(str, "redundancy=5")
        @test contains(str, "fec=4")
        close(client)

        server = UniUDPServer(8887)
        register(server, "/test") do params, msg end
        str = string(server)
        @test contains(str, "1 handler")
        close(server)
    end

    # ==================== ERROR HANDLING TESTS ====================

    @testset "Handler throws exception - server continues" begin
        received = Channel{Any}(10)
        handler_called = Ref(0)

        server = UniUDPServer(8870; inactivity_timeout=0.3, overall_timeout=3.0)

        register(server, "/test/throws") do params, msg
            handler_called[] += 1
            error("Intentional test error")
        end

        register(server, "/test/works") do params, msg
            handler_called[] += 1
            put!(received, params["value"])
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8870; redundancy=4)

        # Send to handler that throws, wait for it to be processed
        send_notify(client, "/test/throws", Dict("x" => 1))
        sleep(0.2)  # Allow server to process and log error

        # Send to handler that works - server should still be running
        send_notify(client, "/test/works", Dict("value" => 42))

        @test timedwait(() -> isready(received), 1.0) == :ok
        @test take!(received) == 42
        @test server.running[]

        close(client)
        close(server)
    end

    @testset "response_callback throws exception - server continues" begin
        callback_calls = Ref(0)
        received = Channel{Any}(10)

        server = UniUDPServer(8869;
            inactivity_timeout=0.3,
            overall_timeout=3.0,
            response_callback = (method, result, msg) -> begin
                callback_calls[] += 1
                if method == "/test/callback_throws"
                    error("Callback intentional error")
                else
                    put!(received, result)
                end
            end
        )

        register(server, "/test/callback_throws") do params, msg
            return "trigger callback error"
        end

        register(server, "/test/callback_works") do params, msg
            return params["value"] * 2
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8869; redundancy=4)

        # Request that causes callback to throw, wait for it to be processed
        send_request(client, "/test/callback_throws", Dict("x" => 1))
        sleep(0.2)  # Allow server to process and log error

        # Request with working callback - server should still be running
        send_request(client, "/test/callback_works", Dict("value" => 21))

        @test timedwait(() -> isready(received), 1.0) == :ok
        @test take!(received) == 42
        @test server.running[]

        close(client)
        close(server)
    end

    @testset "Handler returns nothing for request - callback not invoked" begin
        callback_invoked = Ref(false)
        handler_done = Channel{Bool}(1)

        server = UniUDPServer(8868;
            inactivity_timeout=0.3,
            overall_timeout=2.0,
            response_callback = (method, result, msg) -> (callback_invoked[] = true)
        )

        register(server, "/test/returns_nothing") do params, msg
            # Do some work but return nothing
            _ = params["x"] + 1
            put!(handler_done, true)
            return nothing
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8868; redundancy=4)

        send_request(client, "/test/returns_nothing", Dict("x" => 5))

        # Wait for handler to complete
        @test timedwait(() -> isready(handler_done), 1.0) == :ok
        take!(handler_done)

        # Small wait to ensure callback would have fired if it was going to
        sleep(0.1)

        # Callback should NOT be invoked when handler returns nothing
        @test !callback_invoked[]

        close(client)
        close(server)
    end

    @testset "Unknown method - server logs and continues" begin
        received = Channel{Any}(10)

        server = UniUDPServer(8867; inactivity_timeout=0.3, overall_timeout=3.0)

        register(server, "/test/known") do params, msg
            put!(received, params["value"])
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8867; redundancy=4)

        # Send to unknown method, wait for it to be processed
        send_notify(client, "/test/unknown_method", Dict("x" => 1))
        sleep(0.2)  # Allow server to process and log warning

        # Send to known method - should still work
        send_notify(client, "/test/known", Dict("value" => 99))

        @test timedwait(() -> isready(received), 1.0) == :ok
        @test take!(received) == 99
        @test server.running[]

        close(client)
        close(server)
    end

    # ==================== EDGE CASE TESTS ====================

    @testset "Empty/minimal message" begin
        received = Channel{Any}(10)

        server = UniUDPServer(8866; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/") do params, msg
            put!(received, ("root", params))
        end

        register(server, "/empty") do params, msg
            put!(received, ("empty", params))
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8866; redundancy=4)

        # Send sequentially for predictable test ordering
        send_notify(client, "/", Dict("x" => 1))
        @test timedwait(() -> isready(received), 1.0) == :ok
        tag1, data1 = take!(received)

        # No params
        send_notify(client, "/empty", nothing)
        @test timedwait(() -> isready(received), 1.0) == :ok
        tag2, data2 = take!(received)

        results = Dict(tag1 => data1, tag2 => data2)

        @test haskey(results, "root")
        @test results["root"]["x"] == 1
        @test haskey(results, "empty")
        @test results["empty"] === nothing

        close(client)
        close(server)
    end

    @testset "Unicode in method names and params" begin
        received = Channel{Any}(10)

        server = UniUDPServer(8865; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/données/température") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8865; redundancy=4)

        send_notify(client, "/données/température", Dict(
            "valeur" => 25.5,
            "unité" => "°C",
            "émoji" => "🌡️",
            "中文" => "温度"
        ))

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["valeur"] == 25.5
        @test result["unité"] == "°C"
        @test result["émoji"] == "🌡️"
        @test result["中文"] == "温度"

        close(client)
        close(server)
    end

    @testset "UTF8 body format" begin
        received = Channel{Any}(10)

        server = UniUDPServer(8864; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/utf8") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8864; redundancy=4)

        # Send plain string with UTF8 format
        send_notify(client, "/test/utf8", "Hello, 世界! 🌍";
                    body_format=REPE.BODY_UTF8)

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result == "Hello, 世界! 🌍"

        close(client)
        close(server)
    end

    @testset "Deeply nested data" begin
        received = Channel{Any}(1)

        server = UniUDPServer(8863; inactivity_timeout=0.5, overall_timeout=3.0)

        register(server, "/test/nested") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8863; redundancy=4)

        nested_data = Dict(
            "level1" => Dict(
                "level2" => Dict(
                    "level3" => Dict(
                        "level4" => Dict(
                            "value" => 42,
                            "array" => [1, 2, Dict("nested_in_array" => true)]
                        )
                    )
                )
            ),
            "mixed" => [
                Dict("a" => 1),
                [2, 3, 4],
                "string",
                5.5
            ]
        )

        send_notify(client, "/test/nested", nested_data)

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["level1"]["level2"]["level3"]["level4"]["value"] == 42
        @test result["level1"]["level2"]["level3"]["level4"]["array"][3]["nested_in_array"] == true
        @test result["mixed"][1]["a"] == 1
        @test result["mixed"][2] == [2, 3, 4]

        close(client)
        close(server)
    end

    @testset "Very long method name" begin
        received = Channel{Any}(1)

        long_method = "/" * repeat("a", 500) * "/" * repeat("b", 500)

        server = UniUDPServer(8862; inactivity_timeout=0.5, overall_timeout=3.0)

        register(server, long_method) do params, msg
            put!(received, params["x"])
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8862; redundancy=4)

        send_notify(client, long_method, Dict("x" => 123))

        @test timedwait(() -> isready(received), 1.0) == :ok
        @test take!(received) == 123

        close(client)
        close(server)
    end

    @testset "Register same method twice - override" begin
        received = Channel{Any}(10)

        server = UniUDPServer(8861; inactivity_timeout=0.3, overall_timeout=2.0)

        # First registration
        register(server, "/test/override") do params, msg
            put!(received, "first")
        end

        # Second registration - should override
        register(server, "/test/override") do params, msg
            put!(received, "second")
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8861; redundancy=4)

        send_notify(client, "/test/override", Dict("x" => 1))

        @test timedwait(() -> isready(received), 1.0) == :ok
        @test take!(received) == "second"  # Second handler should be called

        close(client)
        close(server)
    end

    # ==================== CLIENT FEATURE TESTS ====================

    @testset "send_request returns message ID" begin
        client = UniUDPClient(ip"127.0.0.1", 8860)

        id1 = send_request(client, "/test", Dict("x" => 1))
        id2 = send_request(client, "/test", Dict("x" => 2))

        @test id1 isa UInt64
        @test id2 isa UInt64
        @test id1 > 0
        @test id2 > 0

        close(client)
    end

    @testset "send_notify returns message ID" begin
        client = UniUDPClient(ip"127.0.0.1", 8859)

        id1 = send_notify(client, "/test", Dict("x" => 1))
        id2 = send_notify(client, "/test", Dict("x" => 2))

        @test id1 isa UInt64
        @test id2 isa UInt64
        @test id1 > 0
        @test id2 > 0

        close(client)
    end

    @testset "Sequential message IDs" begin
        client = UniUDPClient(ip"127.0.0.1", 8858)

        ids = UInt64[]
        for i in 1:10
            push!(ids, send_notify(client, "/test", Dict("i" => i)))
        end

        # IDs should be strictly increasing
        for i in 2:length(ids)
            @test ids[i] > ids[i-1]
        end

        close(client)
    end

    @testset "Custom bind port" begin
        client = UniUDPClient(ip"127.0.0.1", 8857; bind_port=18857)
        @test isopen(client)
        close(client)
    end

    # ==================== SERVER FEATURE TESTS ====================

    @testset "Default response_callback works" begin
        handler_done = Channel{Bool}(1)

        # Server with no explicit callback should work without errors
        server = UniUDPServer(8856; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test") do params, msg
            put!(handler_done, true)
            return "result that goes to default callback"
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8856; redundancy=4)

        # Should not throw even though there's no custom callback
        send_request(client, "/test", Dict("x" => 1))

        @test timedwait(() -> isready(handler_done), 1.0) == :ok
        @test server.running[]

        close(client)
        close(server)
    end

    @testset "Mutable response_callback" begin
        results1 = Channel{Any}(10)
        results2 = Channel{Any}(10)

        server = UniUDPServer(8855;
            inactivity_timeout=0.2,
            overall_timeout=5.0,
            response_callback = (method, result, msg) -> put!(results1, result)
        )

        register(server, "/test") do params, msg
            return params["value"]
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8855; redundancy=4)

        # Send with first callback
        send_request(client, "/test", Dict("value" => 100))

        # Wait for result with timeout (proper synchronization)
        @test timedwait(() -> isready(results1), 1.0) == :ok
        @test take!(results1) == 100

        # Change callback
        server.response_callback = (method, result, msg) -> put!(results2, result)

        # Send with second callback
        send_request(client, "/test", Dict("value" => 200))

        # Wait for result with timeout
        @test timedwait(() -> isready(results2), 1.0) == :ok
        @test take!(results2) == 200

        close(client)
        close(server)
    end

    @testset "Multiple clients to one server" begin
        received = Channel{Any}(20)

        server = UniUDPServer(8854; inactivity_timeout=0.5, overall_timeout=5.0)

        register(server, "/test") do params, msg
            put!(received, params["client_id"])
        end

        listen(server; async=true)
        yield()

        client1 = UniUDPClient(ip"127.0.0.1", 8854; redundancy=4)
        client2 = UniUDPClient(ip"127.0.0.1", 8854; redundancy=4)

        # Send from both clients
        for i in 1:3
            send_notify(client1, "/test", Dict("client_id" => "client1_$i"))
            send_notify(client2, "/test", Dict("client_id" => "client2_$i"))
        end

        # Wait for at least 4 messages (some may be lost due to UDP)
        for _ in 1:4
            timedwait(() -> isready(received), 2.0)
        end

        # Collect all received
        client1_count = 0
        client2_count = 0
        while isready(received)
            id = take!(received)
            if startswith(id, "client1")
                client1_count += 1
            elseif startswith(id, "client2")
                client2_count += 1
            end
        end

        @test client1_count >= 1  # At least some messages from each client
        @test client2_count >= 1

        close(client1)
        close(client2)
        close(server)
    end

    # ==================== CONCURRENCY TESTS ====================

    @testset "Rapid-fire messages" begin
        received = Channel{Any}(100)
        count = Ref(0)

        server = UniUDPServer(8853; inactivity_timeout=1.0, overall_timeout=10.0)

        register(server, "/test/rapid") do params, msg
            count[] += 1
            put!(received, params["i"])
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8853; redundancy=4)

        # Send many messages rapidly
        n_messages = 20
        for i in 1:n_messages
            send_notify(client, "/test/rapid", Dict("i" => i))
        end

        # Wait for at least half the messages
        for _ in 1:(n_messages ÷ 2)
            timedwait(() -> isready(received), 1.0)
        end

        # Due to UDP, we might lose some, but should get some
        @test count[] >= n_messages ÷ 4

        close(client)
        close(server)
    end

    @testset "Interleaved notify and request" begin
        notify_received = Channel{Any}(20)
        request_results = Channel{Any}(20)

        server = UniUDPServer(8852;
            inactivity_timeout=0.5,
            overall_timeout=5.0,
            response_callback = (method, result, msg) -> put!(request_results, result)
        )

        register(server, "/notify") do params, msg
            put!(notify_received, params["n"])
            return nothing  # Explicit nothing for notify
        end

        register(server, "/request") do params, msg
            return params["n"] * 2
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8852; redundancy=4)

        # Interleave notifications and requests
        for i in 1:5
            send_notify(client, "/notify", Dict("n" => i))
            send_request(client, "/request", Dict("n" => i))
        end

        # Wait for some messages
        for _ in 1:4
            timedwait(() -> isready(notify_received) || isready(request_results), 1.0)
        end

        # Count received
        notify_count = 0
        while isready(notify_received)
            take!(notify_received)
            notify_count += 1
        end

        request_count = 0
        while isready(request_results)
            take!(request_results)
            request_count += 1
        end

        @test notify_count >= 2
        @test request_count >= 2

        close(client)
        close(server)
    end

    # ==================== PROTOCOL TESTS ====================

    @testset "RAW_BINARY body format" begin
        received = Channel{Any}(1)

        server = UniUDPServer(8851; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/binary") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8851; redundancy=4)

        # Send raw binary data
        binary_data = UInt8[0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD]
        send_notify(client, "/test/binary", binary_data;
                    body_format=REPE.BODY_RAW_BINARY)

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result == binary_data

        close(client)
        close(server)
    end

    @testset "Various numeric types" begin
        received = Channel{Any}(1)

        server = UniUDPServer(8850; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/numbers") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8850; redundancy=4)

        send_notify(client, "/test/numbers", Dict(
            "int" => 42,
            "negative" => -100,
            "float" => 3.14159,
            "scientific" => 1.23e-10,
            "zero" => 0,
            "large" => 9007199254740992  # 2^53
        ))

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["int"] == 42
        @test result["negative"] == -100
        @test isapprox(result["float"], 3.14159; atol=1e-10)
        @test isapprox(result["scientific"], 1.23e-10; rtol=1e-5)
        @test result["zero"] == 0
        @test result["large"] == 9007199254740992

        close(client)
        close(server)
    end

    @testset "Boolean and null values" begin
        received = Channel{Any}(1)

        server = UniUDPServer(8849; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/bools") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8849; redundancy=4)

        send_notify(client, "/test/bools", Dict(
            "true_val" => true,
            "false_val" => false,
            "null_val" => nothing
        ))

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["true_val"] == true
        @test result["false_val"] == false
        @test result["null_val"] === nothing

        close(client)
        close(server)
    end

    @testset "Array types" begin
        received = Channel{Any}(1)

        server = UniUDPServer(8848; inactivity_timeout=0.3, overall_timeout=2.0)

        register(server, "/test/arrays") do params, msg
            put!(received, params)
        end

        listen(server; async=true)
        yield()

        client = UniUDPClient(ip"127.0.0.1", 8848; redundancy=4)

        send_notify(client, "/test/arrays", Dict(
            "empty" => [],
            "ints" => [1, 2, 3, 4, 5],
            "strings" => ["a", "b", "c"],
            "mixed" => [1, "two", 3.0, true, nothing]
        ))

        @test timedwait(() -> isready(received), 1.0) == :ok
        result = take!(received)
        @test result["empty"] == []
        @test result["ints"] == [1, 2, 3, 4, 5]
        @test result["strings"] == ["a", "b", "c"]
        @test result["mixed"][1] == 1
        @test result["mixed"][2] == "two"
        @test result["mixed"][4] == true
        @test result["mixed"][5] === nothing

        close(client)
        close(server)
    end

end
