#!/usr/bin/env julia

using REPE
using Base.Threads
using Sockets

println("REPE Concurrent Client Example")
println("==============================")
println("Julia threads available: ", Threads.nthreads())
println()

# Connect to server
client = REPE.REPEClient("localhost", 8080)

# For demonstration, we'll create a simple local server
println("Starting local test server...")
server = REPE.REPEServer("localhost", 8080)

# Register some handlers that simulate different processing times
REPE.register(server, "/fast", function(params, request)
    # Fast operation
    return Dict("result" => "fast response", "input" => params)
end)

REPE.register(server, "/slow", function(params, request)
    # Simulate slower operation
    sleep(0.5)
    return Dict("result" => "slow response", "input" => params)
end)

REPE.register(server, "/compute", function(params, request)
    # Simulate computation
    value = get(params, "value", 0)
    sleep(0.1)  # Simulate work
    return Dict("result" => value ^ 2, "input" => value)
end)

# Start server in background
@async REPE.start_server(server)

# Wait for server to actually start listening
for i in 1:50
    try
        test_socket = Sockets.connect("localhost", 8080)
        close(test_socket)
        println("Server ready after $(i*0.1) seconds")
        break
    catch
        sleep(0.1)
        if i == 50
            error("Server failed to start")
        end
    end
end

try
    REPE.connect(client)
    println("Connected to server\n")
    
    # Example 1: Fire multiple async requests
    println("Example 1: Launching 10 concurrent requests")
    println("--------------------------------------------")
    
    tasks = Task[]
    start_time = time()
    
    for i in 1:10
        task = REPE.send_request_async(client, "/compute", 
                                 Dict("value" => i),
                                 body_format = REPE.BODY_JSON)
        push!(tasks, task)
    end
    
    println("All requests launched, waiting for results...")
    
    # Collect results as they complete
    results = []
    for (i, task) in enumerate(tasks)
        result = fetch(task)
        push!(results, result)
        println("  Task $i completed: $(result["input"]) → $(result["result"])")
    end
    
    elapsed = time() - start_time
    println("Total time for 10 concurrent requests: $(round(elapsed, digits=2))s")
    println("  (Would take ~1s if sequential, but runs in parallel)\n")
    
    # Example 2: Batch operations with mixed endpoints
    println("Example 2: Batch operations with different endpoints")
    println("----------------------------------------------------")
    
    batch_requests = [
        ("/fast", Dict("id" => 1)),
        ("/slow", Dict("id" => 2)),
        ("/fast", Dict("id" => 3)),
        ("/compute", Dict("value" => 42)),
        ("/slow", Dict("id" => 4)),
    ]
    
    start_time = time()
    batch_tasks = REPE.send_batch_async(client, batch_requests, body_format = REPE.BODY_JSON)
    
    println("Batch of $(length(batch_requests)) requests sent")
    
    batch_results = REPE.fetch_batch(batch_tasks)
    for (i, result) in enumerate(batch_results)
        println("  Request $i: $(result)")
    end
    
    elapsed = time() - start_time
    println("Batch completed in: $(round(elapsed, digits=2))s\n")
    
    # Example 3: Mix of requests and notifications
    println("Example 3: Mixed requests and notifications")
    println("-------------------------------------------")
    
    # Send some notifications (no response expected)
    for i in 1:5
        REPE.send_notify(client, "/fast", Dict("notify_id" => i), body_format = REPE.BODY_JSON)
        println("  Sent notification $i")
    end
    
    # Send async requests
    mixed_tasks = Task[]
    for i in 1:5
        task = REPE.send_request_async(client, "/fast", 
                                 Dict("request_id" => i),
                                 body_format = REPE.BODY_JSON)
        push!(mixed_tasks, task)
    end
    
    println("  Waiting for request responses...")
    for (i, task) in enumerate(mixed_tasks)
        result = fetch(task)
        println("  Request $i response: $(result["result"])")
    end
    
    println("\nExample 4: Stress test with many concurrent requests")
    println("----------------------------------------------------")
    
    n_requests = 100
    println("Sending $n_requests concurrent requests...")
    
    stress_tasks = Task[]
    start_time = time()
    
    for i in 1:n_requests
        task = REPE.send_request_async(client, "/fast",
                                 Dict("id" => i),
                                 body_format = REPE.BODY_JSON)
        push!(stress_tasks, task)
    end
    
    # Wait for all to complete
    stress_results = REPE.fetch_batch(stress_tasks)
    elapsed = time() - start_time
    
    println("Completed $n_requests requests in $(round(elapsed, digits=2))s")
    println("Average: $(round(elapsed/n_requests * 1000, digits=2))ms per request")
    println("Throughput: $(round(n_requests/elapsed, digits=0)) requests/second")
    
    # Example 5: Using threads explicitly
    println("\nExample 5: Multi-threaded client usage")
    println("---------------------------------------")
    
    if Threads.nthreads() > 1
        println("Using $(Threads.nthreads()) threads")
        
        thread_results = Vector{Any}(undef, Threads.nthreads())
        
        Threads.@threads for t in 1:Threads.nthreads()
            # Each thread makes its own requests
            thread_id = Threads.threadid()
            local_results = []
            
            for i in 1:5
                result = REPE.send_request(client, "/compute",
                                    Dict("value" => t * 10 + i),
                                    body_format = REPE.BODY_JSON)
                push!(local_results, result["result"])
            end
            
            thread_results[thread_id] = local_results
            println("  Thread $thread_id completed: $local_results")
        end
        
        println("All threads completed successfully!")
    else
        println("Run with JULIA_NUM_THREADS=4 julia concurrent_client.jl for multi-threading")
    end
    
catch e
    println("Error: ", e)
finally
    REPE.disconnect(client)
    REPE.stop_server(server)
    println("\nClient disconnected and server stopped")
end

println("\n✅ Concurrent operations demonstration complete!")
println("The thread-safe client enables:")
println("  • Multiple concurrent requests from one connection")
println("  • Async/await style programming")
println("  • Batch operations")
println("  • Multi-threaded client usage")
println("  • High throughput RPC communication")