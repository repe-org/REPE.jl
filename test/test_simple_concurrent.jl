#!/usr/bin/env julia

using Test
using REPE

@testset "Simple Concurrent Test" begin
    server = REPE.Server("localhost", 9999)
    
    # Register handler
    REPE.register(server, "/echo", function(params, request)
        return params
    end)
    
    # Start server with proper async handling
    server_task = @async REPE.start_server(server)
    
    # Wait a bit longer and check if server is running
    for i in 1:10
        sleep(0.5)
        if server.running
            println("Server started after $(i*0.5) seconds")
            break
        end
    end
    
    @test server.running
    
    client = REPE.Client("localhost", 9999)
    
    try
        REPE.connect(client)
        @test client.connected
        
        # Test sync request
        result = REPE.send_request(client, "/echo", Dict("test" => "sync"), body_format = REPE.BODY_JSON)
        @test result["test"] == "sync"
        println("✓ Sync request works")
        
        # Test async request
        task = REPE.send_request_async(client, "/echo", Dict("test" => "async"), body_format = REPE.BODY_JSON)
        result = fetch(task)
        @test result["test"] == "async"
        println("✓ Async request works")
        
        # Test multiple concurrent requests
        tasks = []
        for i in 1:5
            task = REPE.send_request_async(client, "/echo", Dict("id" => i), body_format = REPE.BODY_JSON)
            push!(tasks, task)
        end
        
        results = [fetch(task) for task in tasks]
        for i in 1:5
            @test results[i]["id"] == i
        end
        println("✓ Multiple concurrent requests work")
        
    finally
        REPE.disconnect(client)
        REPE.stop_server(server)
    end
end