#!/usr/bin/env julia

using REPE
using Base.Threads
using Sockets

println("REPE Concurrent Client Example (Working Demo)")
println("============================================")
println("Julia threads available: ", Threads.nthreads())
println()

# This example demonstrates the concurrent capabilities of the REPE client
# It uses a C++ server for actual network testing. To run this example:
# 1. Build and run the C++ server: cd cpp_server && make && ./repe_server
# 2. Run this Julia client example

# Configuration
SERVER_HOST = "localhost"
SERVER_PORT = 8080

# Create client
client = REPE.REPEClient(SERVER_HOST, SERVER_PORT)

# Helper function to test if server is available
function server_available(host, port)
    try
        test_socket = Sockets.connect(host, port)
        close(test_socket)
        return true
    catch
        return false
    end
end

if !server_available(SERVER_HOST, SERVER_PORT)
    println("❌ Server not available at $SERVER_HOST:$SERVER_PORT")
    println()
    println("To run this example with a real server:")
    println("1. Build the C++ server:")
    println("   cd cpp_server")
    println("   make")
    println("   ./repe_server")
    println()
    println("2. Then run this Julia client again")
    println()
    println("For now, demonstrating client capabilities without server...")
    println()
    
    # Demonstrate concurrent capabilities without server
    include("concurrent_demo.jl")
    exit(0)
end

println("✅ Server detected at $SERVER_HOST:$SERVER_PORT")
println("Connecting to server...")

try
    REPE.connect(client)
    println("Connected to server successfully!")
    println()
    
    # Example 1: Basic concurrent requests
    println("Example 1: Concurrent arithmetic operations")
    println("------------------------------------------")
    
    tasks = Task[]
    start_time = time()
    
    # Launch multiple concurrent requests
    for i in 1:10
        task = REPE.send_request_async(client, "/add", 
                                     Dict("a" => i, "b" => i * 2),
                                     body_format = REPE.BODY_JSON)
        push!(tasks, task)
    end
    
    println("Launched 10 concurrent addition requests...")
    
    # Collect results as they complete
    results = []
    for (i, task) in enumerate(tasks)
        result = fetch(task)
        push!(results, result)
        println("  Request $i: $(result["a"]) + $(result["b"]) = $(result["result"])")
    end
    
    elapsed = time() - start_time
    println("Completed in $(round(elapsed, digits=3))s")
    println()
    
    # Example 2: Batch operations
    println("Example 2: Batch operations")
    println("---------------------------")
    
    batch_requests = Tuple{String, Any}[
        ("/add", Dict("a" => 10, "b" => 20)),
        ("/multiply", Dict("a" => 5, "b" => 6)),
        ("/add", Dict("a" => 100, "b" => 200)),
        ("/multiply", Dict("a" => 7, "b" => 8)),
    ]
    
    start_time = time()
    batch_tasks = REPE.send_batch_async(client, batch_requests, body_format = REPE.BODY_JSON)
    
    println("Sent batch of $(length(batch_requests)) requests...")
    
    batch_results = REPE.fetch_batch(batch_tasks)
    for (i, result) in enumerate(batch_results)
        request = batch_requests[i]
        method = request[1]
        params = request[2]
        println("  $method: $(params["a"]) $( method == "/add" ? "+" : "×") $(params["b"]) = $(result["result"])")
    end
    
    elapsed = time() - start_time
    println("Batch completed in $(round(elapsed, digits=3))s")
    println()
    
    # Example 3: Mixed operations with notifications
    println("Example 3: Mixed requests and notifications")
    println("------------------------------------------")
    
    # Send some notifications (fire-and-forget)
    for i in 1:3
        REPE.send_notify(client, "/add", Dict("a" => i, "b" => i * 10), body_format = REPE.BODY_JSON)
        println("  Sent notification: $i + $(i * 10)")
    end
    
    # Send async requests
    mixed_tasks = Task[]
    for i in 1:3
        task = REPE.send_request_async(client, "/multiply", 
                                     Dict("a" => i, "b" => i + 1),
                                     body_format = REPE.BODY_JSON)
        push!(mixed_tasks, task)
    end
    
    println("  Waiting for multiplication responses...")
    for (i, task) in enumerate(mixed_tasks)
        result = fetch(task)
        println("  Response $i: $(result["a"]) × $(result["b"]) = $(result["result"])")
    end
    println()
    
    # Example 4: High throughput test
    println("Example 4: High throughput test")
    println("-------------------------------")
    
    n_requests = 50
    println("Sending $n_requests concurrent requests...")
    
    stress_tasks = Task[]
    start_time = time()
    
    for i in 1:n_requests
        task = REPE.send_request_async(client, "/add",
                                     Dict("a" => i, "b" => 1),
                                     body_format = REPE.BODY_JSON)
        push!(stress_tasks, task)
    end
    
    # Wait for all to complete
    stress_results = REPE.fetch_batch(stress_tasks)
    elapsed = time() - start_time
    
    println("Completed $n_requests requests in $(round(elapsed, digits=3))s")
    println("Average: $(round(elapsed/n_requests * 1000, digits=2))ms per request")
    println("Throughput: $(round(n_requests/elapsed, digits=0)) requests/second")
    println()
    
    # Example 5: Multi-threaded usage
    if Threads.nthreads() > 1
        println("Example 5: Multi-threaded client usage")
        println("--------------------------------------")
        println("Using $(Threads.nthreads()) threads")
        
        thread_results = Vector{Any}(undef, Threads.nthreads())
        
        Threads.@threads for t in 1:Threads.nthreads()
            thread_id = Threads.threadid()
            local_results = []
            
            for i in 1:3
                result = REPE.send_request(client, "/multiply",
                                        Dict("a" => t, "b" => i),
                                        body_format = REPE.BODY_JSON)
                push!(local_results, result["result"])
            end
            
            thread_results[thread_id] = local_results
            println("  Thread $thread_id completed: $local_results")
        end
        
        println("All threads completed successfully!")
    else
        println("Example 5: Single-threaded mode")
        println("-------------------------------")
        println("Run with JULIA_NUM_THREADS=4 julia concurrent_client_working.jl for multi-threading")
    end
    
catch e
    println("❌ Error during execution: ", e)
finally
    REPE.disconnect(client)
    println("\n✅ Client disconnected")
end

println("\n🎉 Concurrent operations demonstration complete!")
println("The thread-safe client successfully demonstrated:")
println("  • Multiple concurrent requests from one connection")
println("  • Async/await style programming")
println("  • Batch operations")
println("  • Mixed requests and notifications")
println("  • High throughput RPC communication")
if Threads.nthreads() > 1
    println("  • Multi-threaded client usage")
end