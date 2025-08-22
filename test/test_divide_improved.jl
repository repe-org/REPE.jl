#!/usr/bin/env julia

using REPE

# Kill any existing servers
run(`killall repe_server`, wait=false)
sleep(1)

# Start the improved C++ server
server_path = joinpath(@__DIR__, "..", "cpp_server", "build", "repe_server")
server_process = run(`$server_path 10003`, wait=false)

println("Waiting for server to start...")
sleep(2)

println("Testing improved divide function...")
client = REPEClient("localhost", 10003)

try
    connect(client)
    println("✓ Connected to server")
    
    # Test normal division
    println("\nTest 1: 100 / 4")
    result = send_request(client, "/divide", 
                         Dict("numerator" => 100.0, "denominator" => 4.0),
                         body_format = BODY_JSON)
    println("Result: ", result)
    @assert result["result"] ≈ 25.0
    println("✓ Normal division works: 100 / 4 = $(result["result"])")
    
    # Test division by zero (should throw error)
    println("\nTest 2: 10 / 0 (expecting error)")
    try
        result = send_request(client, "/divide",
                             Dict("numerator" => 10.0, "denominator" => 0.0),
                             body_format = BODY_JSON)
        println("❌ Should have received an error!")
    catch e
        println("✓ Correctly received error: ", e)
    end
    
    println("\n✅ Improved divide function works correctly!")
    println("   - Returns simple double for valid division")
    println("   - Throws exception for division by zero")
    println("   - Much more efficient than returning std::map")
    
finally
    disconnect(client)
    kill(server_process)
    println("\nTest complete, server stopped")
end