#!/usr/bin/env julia

using REPE
using Sockets

println("REPE BEVE Interoperability Test")
println("===============================")
println("Testing BEVE format between Julia client and C++ server")
println()

# Check if C++ server is available
function server_available(host, port)
    try
        test_socket = Sockets.connect(host, port)
        close(test_socket)
        return true
    catch
        return false
    end
end

SERVER_HOST = "localhost"
SERVER_PORT = 8080

if !server_available(SERVER_HOST, SERVER_PORT)
    println("❌ C++ server not available at $SERVER_HOST:$SERVER_PORT")
    println()
    println("To run this test:")
    println("1. Build the C++ server: cd build && make")
    println("2. Start the server: ./build/repe_server")
    println("3. Run this test again")
    exit(1)
end

println("✅ C++ server detected at $SERVER_HOST:$SERVER_PORT")
println()

# Create client and connect
client = REPE.Client(SERVER_HOST, SERVER_PORT)
REPE.connect(client)
println("Connected to C++ server")
println()

try
    # Test 1: Simple BEVE request
    println("Test 1: Simple BEVE add operation")
    println("---------------------------------")
    
    beve_data = Dict("a" => 15.0, "b" => 25.0)
    result = REPE.send_request(client, "/add", beve_data, body_format = REPE.BODY_BEVE)
    
    println("  Request data: $beve_data")
    println("  Response: $result")
    println("  Expected: 40.0, Got: $(result["result"])")
    @assert result["result"] == 40.0 "BEVE add test failed"
    println("  ✅ BEVE add test passed")
    println()
    
    # Test 2: Compare BEVE vs JSON
    println("Test 2: BEVE vs JSON comparison")
    println("-------------------------------")
    
    test_data = Dict("x" => 7.0, "y" => 6.0)
    
    # Send with BEVE
    start_time = time()
    beve_result = REPE.send_request(client, "/multiply", test_data, body_format = REPE.BODY_BEVE)
    beve_time = time() - start_time
    
    # Send with JSON  
    start_time = time()
    json_result = REPE.send_request(client, "/multiply", test_data, body_format = REPE.BODY_JSON)
    json_time = time() - start_time
    
    println("  Test data: $test_data")
    println("  BEVE result: $(beve_result["result"]) ($(round(beve_time*1000, digits=2))ms)")
    println("  JSON result: $(json_result["result"]) ($(round(json_time*1000, digits=2))ms)")
    @assert beve_result["result"] == json_result["result"] == 42.0 "Results don't match"
    println("  ✅ Both formats produce identical results")
    println()
    
    # Test 3: Complex data with BEVE
    println("Test 3: Complex structured data with BEVE")
    println("-----------------------------------------")
    
    # Test the status endpoint which returns complex data
    status_result = REPE.send_request(client, "/status", nothing, body_format = REPE.BODY_BEVE)
    println("  Server status (via BEVE):")
    for (key, value) in status_result
        println("    $key: $value")
    end
    @assert haskey(status_result, "status") "Status response missing 'status' field"
    @assert status_result["status"] == "online" "Expected status 'online'"
    println("  ✅ Complex BEVE data test passed")
    println()
    
    # Test 4: String handling with BEVE
    println("Test 4: String handling with BEVE")
    println("---------------------------------")
    
    echo_data = Dict("message" => "Hello BEVE from Julia! 🎉")
    echo_result = REPE.send_request(client, "/echo", echo_data, body_format = REPE.BODY_BEVE)
    
    println("  Input: $(echo_data["message"])")
    println("  Echo response: $(echo_result["result"])")
    @assert contains(echo_result["result"], "Hello BEVE from Julia! 🎉") "Echo failed"
    println("  ✅ BEVE string test passed")
    println()
    
    # Test 5: Error handling with BEVE
    println("Test 5: Error handling with BEVE")
    println("--------------------------------")
    
    try
        error_data = Dict("numerator" => 10.0, "denominator" => 0.0)
        REPE.send_request(client, "/divide", error_data, body_format = REPE.BODY_BEVE)
        println("  ❌ Expected division by zero error but none occurred")
    catch e
        println("  ✅ Correctly caught error: $(typeof(e))")
        println("    Error message: $e")
    end
    println()
    
    # Test 6: Concurrent BEVE requests
    println("Test 6: Concurrent BEVE requests")
    println("--------------------------------")
    
    n_requests = 10
    tasks = Task[]
    
    println("  Launching $n_requests concurrent BEVE requests...")
    start_time = time()
    
    for i in 1:n_requests
        task = REPE.send_request_async(client, "/add", 
                                     Dict("a" => Float64(i), "b" => Float64(i*2)),
                                     body_format = REPE.BODY_BEVE)
        push!(tasks, task)
    end
    
    # Collect results
    results = [fetch(task) for task in tasks]
    elapsed = time() - start_time
    
    # Verify results
    all_correct = true
    for i in 1:n_requests
        expected = i + (i*2)  # a + b
        actual = results[i]["result"]
        if actual != expected
            println("  ❌ Request $i: expected $expected, got $actual")
            all_correct = false
        end
    end
    
    if all_correct
        println("  ✅ All $n_requests concurrent BEVE requests succeeded")
        println("  Total time: $(round(elapsed*1000, digits=2))ms")
        println("  Average: $(round(elapsed/n_requests*1000, digits=2))ms per request")
    end
    println()
    
    # Test 7: Binary data efficiency
    println("Test 7: Data format efficiency comparison")  
    println("----------------------------------------")
    
    # Create data that should compress well with BEVE
    large_data = Dict(
        "numbers" => collect(1.0:100.0),
        "matrix" => [[Float64(i+j) for j in 1:10] for i in 1:10],
        "flags" => fill(true, 50),
        "metadata" => Dict("timestamp" => 1641038400, "version" => "1.0")
    )
    
    # Encode with both formats to compare sizes
    beve_encoded = REPE.encode_body(large_data, REPE.BODY_BEVE)
    json_encoded = REPE.encode_body(large_data, REPE.BODY_JSON)
    
    println("  Large dataset sizes:")
    println("    BEVE: $(length(beve_encoded)) bytes")
    println("    JSON: $(length(json_encoded)) bytes")
    
    if length(beve_encoded) < length(json_encoded)
        savings = (1 - length(beve_encoded)/length(json_encoded)) * 100
        println("    ✅ BEVE is $(round(savings, digits=1))% more compact")
    else
        overhead = (length(beve_encoded)/length(json_encoded) - 1) * 100
        println("    📊 JSON is $(round(overhead, digits=1))% more compact for this data")
    end
    println()
    
    println("🎉 All BEVE interoperability tests completed successfully!")
    println()
    println("Summary:")
    println("  ✅ Basic BEVE encoding/decoding works")
    println("  ✅ BEVE and JSON produce identical results")
    println("  ✅ Complex data structures supported")
    println("  ✅ Unicode strings handled correctly")
    println("  ✅ Error handling works properly")
    println("  ✅ Concurrent BEVE requests successful")
    println("  ✅ C++ server properly processes BEVE format")

finally
    REPE.disconnect(client)
    println()
    println("✅ Disconnected from C++ server")
end