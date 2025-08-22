#!/usr/bin/env julia

using REPE
using Test

println("Testing Julia client with Glaze C++ server on port 9999...")

client = REPE.REPEClient("localhost", 9999)

try
    REPE.connect(client)
    println("✓ Connected to Glaze C++ server")
    
    # Test add
    println("\nTesting add(10, 20)...")
    result = REPE.send_request(client, "/add", 
                              Dict("a" => 10.0, "b" => 20.0),
                              body_format = REPE.BODY_JSON)
    println("Result: ", result)
    @assert result["result"] ≈ 30.0
    println("✓ Add works: 10 + 20 = $(result["result"])")
    
    # Test multiply
    println("\nTesting multiply(5, 7)...")
    result = REPE.send_request(client, "/multiply",
                              Dict("x" => 5.0, "y" => 7.0),
                              body_format = REPE.BODY_JSON)
    println("Result: ", result)
    @assert result["result"] ≈ 35.0
    println("✓ Multiply works: 5 × 7 = $(result["result"])")
    
    # Test divide
    println("\nTesting divide(100, 4)...")
    result = REPE.send_request(client, "/divide",
                              Dict("numerator" => 100.0, "denominator" => 4.0),
                              body_format = REPE.BODY_JSON)
    println("Result: ", result)
    @assert result["result"] ≈ 25.0
    println("✓ Divide works: 100 ÷ 4 = $(result["result"])")
    
    # Test echo
    println("\nTesting echo...")
    result = REPE.send_request(client, "/echo",
                              Dict("message" => "Hello from Julia!"),
                              body_format = REPE.BODY_JSON)
    println("Result: ", result)
    @assert result["result"] == "Echo: Hello from Julia!"
    println("✓ Echo works: $(result["result"])")
    
    # Test status
    println("\nTesting status...")
    result = REPE.send_request(client, "/status", nothing,
                              body_format = REPE.BODY_JSON)
    println("Result: ", result)
    @assert result["status"] == "online"
    println("✓ Status works: $(result["status"]), Version: $(result["version"])")
    
    # Test notification
    println("\nSending notification...")
    REPE.send_notify(client, "/echo", 
                   Dict("message" => "This is a notification"),
                   body_format = REPE.BODY_JSON)
    println("✓ Notification sent")
    
    # Test error handling
    println("\nTesting error handling (non-existent method)...")
    try
        REPE.send_request(client, "/nonexistent", Dict(),
                        body_format = REPE.BODY_JSON)
        println("❌ Should have thrown an error")
    catch e
        println("✓ Error caught: ", e)
    end
    
    println("\n✅ All tests passed! Julia client successfully communicates with Glaze C++ server!")
    
catch e
    println("❌ Error: ", e)
    rethrow(e)
finally
    REPE.disconnect(client)
    println("\nDisconnected from server")
end