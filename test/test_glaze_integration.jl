using REPE
using Test
using Sockets

println("Starting Glaze C++ server integration test...")

# Start the C++ server in the background
server_path = joinpath(@__DIR__, "..", "cpp_server", "build", "repe_server")
server_process = run(`$server_path 8081`, wait=false)

# Give server time to start
println("Waiting for C++ server to start...")
sleep(2)

@testset "Glaze C++ Server Integration" begin
    client = REPE.Client("localhost", 8081)
    
    try
        REPE.connect(client)
        println("Connected to Glaze C++ server")
        
        @testset "Basic Math Operations" begin
            # Test add
            result = REPE.send_request(client, "/add", 
                                      Dict("a" => 10.0, "b" => 20.0),
                                      body_format = REPE.BODY_JSON)
            @test result["result"] ≈ 30.0
            println("✓ Add: 10 + 20 = $(result["result"])")
            
            # Test multiply
            result = REPE.send_request(client, "/multiply",
                                      Dict("x" => 5.0, "y" => 7.0),
                                      body_format = REPE.BODY_JSON)
            @test result["result"] ≈ 35.0
            println("✓ Multiply: 5 × 7 = $(result["result"])")
            
            # Test divide
            result = REPE.send_request(client, "/divide",
                                      Dict("numerator" => 100.0, "denominator" => 4.0),
                                      body_format = REPE.BODY_JSON)
            @test result["result"] ≈ 25.0
            println("✓ Divide: 100 ÷ 4 = $(result["result"])")
            
            # Test divide by zero
            result = REPE.send_request(client, "/divide",
                                      Dict("numerator" => 10.0, "denominator" => 0.0),
                                      body_format = REPE.BODY_JSON)
            @test result["error"] == -1.0
            println("✓ Divide by zero handled correctly")
        end
        
        @testset "String Operations" begin
            # Test echo
            result = REPE.send_request(client, "/echo",
                                      Dict("message" => "Hello from Julia!"),
                                      body_format = REPE.BODY_JSON)
            @test result["result"] == "Echo: Hello from Julia!"
            println("✓ Echo: $(result["result"])")
        end
        
        @testset "Status Check" begin
            # Test status
            result = REPE.send_request(client, "/status", nothing,
                                      body_format = REPE.BODY_JSON)
            @test result["status"] == "online"
            @test result["version"] == "1.0.0"
            println("✓ Status: $(result["status"]), Version: $(result["version"])")
        end
        
        @testset "Error Handling" begin
            # Test non-existent method
            try
                REPE.send_request(client, "/nonexistent", Dict(),
                                body_format = REPE.BODY_JSON)
                @test false # Should have thrown an error
            catch e
                @test occursin("Method not found", string(e)) || occursin("RPC Error", string(e))
                println("✓ Method not found error handled correctly")
            end
        end
        
        @testset "Notifications" begin
            # Send a notification (no response expected)
            REPE.send_notify(client, "/echo", 
                           Dict("message" => "Notification test"),
                           body_format = REPE.BODY_JSON)
            println("✓ Notification sent successfully")
        end
        
        println("\n✅ All Glaze integration tests passed!")
        
    finally
        REPE.disconnect(client)
        kill(server_process)
        println("Glaze C++ server stopped")
    end
end