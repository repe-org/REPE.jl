#!/usr/bin/env julia

using REPE
using Sockets

println("Manual concurrent test...")

# Test the actual async functionality without using the server
println("Testing async task creation...")

# Test 1: Simple async tasks work
tasks = []
for i in 1:5
    task = @async begin
        sleep(0.1)
        return i * 2
    end
    push!(tasks, task)
end

results = [fetch(task) for task in tasks]
println("Async results: ", results)

# Test 2: Test the client's async methods without server connection
println("\nTesting client async methods (no server)...")
client = REPE.Client("localhost", 9999)

# Test ID generation
ids = []
for i in 1:10
    push!(ids, REPE._get_next_id(client))
end
println("Generated IDs: ", ids)
println("All unique: ", length(unique(ids)) == 10)

# Test 3: Test request preparation (will fail to send but we can test the async wrapper)
println("\nTesting async request preparation...")
try
    task = REPE.send_request_async(client, "/test", Dict("a" => 1), body_format=REPE.BODY_JSON)
    println("Async task created: ", typeof(task))
    # This will fail because no server, but the task should be created
    fetch(task)
catch e
    println("Expected error (no server): ", typeof(e))
end

println("\nManual test completed!")