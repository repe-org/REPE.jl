#!/bin/bash

echo "Starting Glaze C++ REPE server on port 10002..."
../cpp_server/build/repe_server 10002 &
SERVER_PID=$!

echo "Server PID: $SERVER_PID"
sleep 3

echo "Running Julia client test..."
julia --project=.. <<'EOF'
using REPE

println("Connecting to Glaze server on port 10002...")
client = REPEClient("127.0.0.1", 10002)

try
    connect(client)
    println("✓ Connected successfully!")
    
    # Test add
    result = send_request(client, "/add", Dict("a" => 10.0, "b" => 20.0), body_format = REPE.BODY_JSON)
    println("Add result: ", result)
    
    # Test improved divide
    println("\nTesting improved divide function...")
    result = send_request(client, "/divide", Dict("numerator" => 100.0, "denominator" => 4.0), body_format = REPE.BODY_JSON)
    println("✓ Divide 100/4 = ", result["result"])
    
    # Test division by zero
    try
        send_request(client, "/divide", Dict("numerator" => 10.0, "denominator" => 0.0), body_format = REPE.BODY_JSON)
        println("❌ Division by zero should have failed!")
    catch e
        println("✓ Division by zero correctly rejected")
    end
    
    # Test status
    result = send_request(client, "/status", nothing, body_format = REPE.BODY_JSON)
    println("Status: ", result)
    
    println("✅ Success! Julia client works with Glaze C++ server!")
catch e
    println("❌ Error: ", e)
finally
    disconnect(client)
end
EOF

echo "Killing server..."
kill $SERVER_PID 2>/dev/null

echo "Test complete!"