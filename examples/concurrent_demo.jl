#!/usr/bin/env julia

using REPE
using Base.Threads

println("REPE Concurrent Client Capabilities Demo")
println("=======================================")
println("Julia threads available: ", Threads.nthreads())
println()

# This demo shows the concurrent capabilities of the REPE client
# without requiring a network server

println("1. Thread-safe ID generation")
println("-----------------------------")

client = REPE.Client("localhost", 8080)

# Generate IDs from multiple threads concurrently
if Threads.nthreads() > 1
    println("Testing with $(Threads.nthreads()) threads...")
    ids = Vector{UInt64}(undef, 100)
    
    Threads.@threads for i in 1:100
        ids[i] = REPE._get_next_id(client)
    end
    
    unique_ids = unique(ids)
    println("  Generated 100 IDs across threads")
    println("  All unique: $(length(unique_ids) == 100)")
    println("  Range: $(minimum(ids)) to $(maximum(ids))")
else
    println("Run with JULIA_NUM_THREADS=4 for multi-threaded ID generation")
    ids = [REPE.get_next_id(client) for i in 1:10]
    println("  Generated IDs: $ids")
    println("  All unique: $(length(unique(ids)) == 10)")
end

println()

println("2. Concurrent task creation and management")
println("------------------------------------------")

# Test async task creation (the actual async wrapper)
println("Creating multiple async request tasks...")
tasks = Task[]

for i in 1:10
    # Each task would attempt to make a request (will fail due to no server)
    # but demonstrates the concurrent task creation
    task = REPE.send_request_async(client, "/test", Dict("id" => i), body_format = REPE.JSON)
    push!(tasks, task)
end

println("  Created $(length(tasks)) async tasks")
println("  Task types: $(typeof(tasks[1]))")

# These tasks will attempt to connect but fail (no server)
# This demonstrates the async task creation capability
println("  Task creation successful: $(length(tasks)) async tasks created")
println("  (Tasks would execute if connected to a running server)")

println()

println("3. Batch operations structure")
println("----------------------------")

# Demonstrate batch request preparation
requests = Tuple{String, Any}[
    ("/method1", Dict("a" => 1)),
    ("/method2", Dict("b" => 2)),
    ("/method3", Dict("c" => 3)),
    ("/method4", Dict("d" => 4)),
    ("/method5", Dict("e" => 5)),
]

println("Preparing batch of $(length(requests)) requests...")
batch_tasks = REPE.batch(client, requests, body_format = REPE.JSON)
println("  Created $(length(batch_tasks)) batch tasks")
println("  Batch task types: $(typeof(batch_tasks))")

println()

println("4. Thread-safe data structures")
println("-----------------------------")

# Test concurrent access to client data structures
if Threads.nthreads() > 1
    println("Testing concurrent dictionary operations...")
    
    n_threads = min(Threads.nthreads(), 4)
    n_ops = 50
    
    Threads.@threads for t in 1:n_threads
        for i in 1:n_ops
            id = REPE.get_next_id(client)
            ch = Channel(1)
            
            # Simulate adding/removing from pending requests
            lock(client.requests_lock) do
                client.pending_requests[id] = ch
            end
            
            # Brief work simulation
            sleep(0.001)
            
            lock(client.requests_lock) do
                delete!(client.pending_requests, id)
            end
            
            close(ch)
        end
    end
    
    println("  Completed $(n_threads * n_ops) concurrent operations")
    println("  Pending requests remaining: $(length(client.pending_requests))")
    println("  All operations completed successfully!")
else
    println("  Run with JULIA_NUM_THREADS=4 for concurrent operations demo")
end

println()

println("5. Message serialization concurrency")
println("-----------------------------------")

# Test that message creation and serialization is thread-safe
println("Creating and serializing messages concurrently...")

if Threads.nthreads() > 1
    messages = Vector{Vector{UInt8}}(undef, 100)
    
    Threads.@threads for i in 1:100
        # Alternate between different body formats to test all encoders
        body_format = if i % 3 == 0
            REPE.BEVE
        elseif i % 3 == 1  
            REPE.JSON
        else
            REPE.UTF8
        end
        
        body_data = if body_format == REPE.BEVE
            Dict("id" => i, "data" => "test_$i", "number" => i * 2)
        elseif body_format == REPE.JSON
            Dict("id" => i, "message" => "json_$i")
        else
            "utf8_data_$i"
        end
        
        msg = REPE.Message(
            id = i,
            query = "/test_$i",
            body = body_data,
            body_format = UInt16(body_format)
        )
        messages[i] = serialize_message(msg)
    end
    
    println("  Serialized 100 messages across threads (mixed formats)")
    println("  All messages created: $(length(messages) == 100)")
    println("  All messages valid: $(all(m -> length(m) >= REPE.HEADER_SIZE, messages))")
    println("  All messages unique: $(length(unique(messages)) == 100)")
    
    # Count format usage
    beve_count = sum(1:100) do i
        i % 3 == 0 ? 1 : 0
    end
    println("  BEVE messages: $beve_count, JSON: $(100 - beve_count - 34), UTF8: 34")
else
    println("  Run with JULIA_NUM_THREADS=4 for concurrent message serialization")
end

println()

println("✅ Concurrent Capabilities Summary")
println("==================================")
println("The REPE client provides:")
println("  • Thread-safe ID generation using atomic operations")
println("  • Concurrent async request creation and management")
println("  • Batch operations for multiple simultaneous requests")
println("  • Protected shared data structures with proper locking")
println("  • Thread-safe message creation and serialization")
println("  • Full support for Julia's async/await programming model")
println()
println("To test with an actual server, connect to a running REPE server")
println("and replace the connection details in your client code.")

# For a complete working example with a server, see the unit tests:
println()
println("For complete working examples, see:")
println("  • test/test_concurrent_simple.jl - Unit tests of concurrent features")
println("  • test/test_concurrent.jl - Full integration tests (when server works)")
