#!/usr/bin/env julia

using REPE
using Base.Threads

println("Testing async functionality...")
println("Threads available: ", Threads.nthreads())

# Create server
server = REPE.REPEServer("localhost", 9999)

# Register a simple handler
REPE.register(server, "/echo", function(params, request)
    println("Server received: ", params)
    return params
end)

# Start server
@async REPE.start_server(server)
sleep(2)  # Give server more time to start

# Create client
client = REPE.REPEClient("localhost", 9999)
REPE.connect(client)

try
    println("\n1. Testing synchronous request...")
    result = REPE.send_request(client, "/echo", Dict("test" => "sync"), body_format = REPE.BODY_JSON)
    println("Sync result: ", result)
    
    println("\n2. Testing asynchronous request...")
    task = REPE.send_request_async(client, "/echo", Dict("test" => "async"), body_format = REPE.BODY_JSON)
    println("Task created: ", task)
    result = fetch(task)
    println("Async result: ", result)
    
    println("\n3. Testing multiple async requests...")
    tasks = []
    for i in 1:3
        task = REPE.send_request_async(client, "/echo", Dict("id" => i), body_format = REPE.BODY_JSON)
        push!(tasks, task)
        println("Created task $i")
    end
    
    for (i, task) in enumerate(tasks)
        result = fetch(task)
        println("Task $i result: ", result)
    end
    
    println("\nAll tests completed successfully!")
    
finally
    REPE.disconnect(client)
    REPE.stop_server(server)
end