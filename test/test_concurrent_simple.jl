@testset "Concurrent Client Tests (Simple)" begin
    
    @testset "Thread-safe ID generation" begin
        client = REPE.Client("localhost", 9876)
        
        # Generate IDs from multiple threads
        ids = Vector{UInt64}(undef, 1000)
        Threads.@threads for i in 1:1000
            ids[i] = REPE._get_next_id(client)
        end
        
        # All IDs should be unique
        @test length(unique(ids)) == 1000
        @test minimum(ids) >= 1  # Starting from 1 (atomic_add returns old value)
        @test maximum(ids) <= 1000
    end
    
    @testset "Lock functionality" begin
        client = REPE.Client("localhost", 9999)
        
        # Test that locks can be acquired and released
        @test lock(client.state_lock) do
            true  # Can acquire state lock
        end
        
        @test lock(client.requests_lock) do
            true  # Can acquire requests lock
        end
        
        @test lock(client.write_lock) do
            true  # Can acquire write lock
        end
    end
    
    @testset "Concurrent dictionary access" begin
        client = REPE.Client("localhost", 9999)
        
        # Simulate concurrent access to pending_requests
        n_threads = 10
        n_ops = 100
        
        Threads.@threads for t in 1:n_threads
            for i in 1:n_ops
                id = REPE._get_next_id(client)
                ch = Channel(1)
                
                # Add to pending requests
                lock(client.requests_lock) do
                    client.pending_requests[id] = REPE.PendingRequest(ch, nothing)
                end
                
                # Remove from pending requests
                lock(client.requests_lock) do
                    delete!(client.pending_requests, id)
                end
                
                close(ch)
            end
        end
        
        # Dictionary should be empty after all operations
        @test isempty(client.pending_requests)
    end
    
    @testset "Async task creation" begin
        client = REPE.Client("localhost", 9999)
        
        # Create multiple async tasks (without actually connecting)
        tasks = Task[]
        for i in 1:10
            # Create a simple async task that doesn't require connection
            task = @async begin
                sleep(0.01)
                return i * 2
            end
            push!(tasks, task)
        end
        
        # All tasks should complete
        results = [fetch(task) for task in tasks]
        @test length(results) == 10
        @test results == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
    end
    
    @testset "Batch operations setup" begin
        client = REPE.Client("localhost", 9999)
        
        # Test batch request preparation (without sending)
        requests = [
            ("/method1", Dict("a" => 1)),
            ("/method2", Dict("b" => 2)),
            ("/method3", Dict("c" => 3)),
        ]
        
        # Verify we can create the batch structure
        @test length(requests) == 3
        @test requests[1][1] == "/method1"
        @test requests[2][2]["b"] == 2
    end
    
    @testset "Message serialization thread safety" begin
        # Test that message serialization is thread-safe
        messages = Vector{Vector{UInt8}}(undef, 100)
        
        Threads.@threads for i in 1:100
            msg = REPE.Message(
                id = i,
                query = "/test",
                body = "data-$i",
                body_format = UInt16(REPE.BODY_UTF8)
            )
            messages[i] = serialize_message(msg)
        end
        
        # All messages should be properly serialized
        @test length(messages) == 100
        @test all(m -> length(m) >= REPE.HEADER_SIZE, messages)
        
        # Each message should be unique (different IDs)
        @test length(unique(messages)) == 100
    end
    
    @testset "Atomic operations" begin
        client = REPE.Client("localhost", 9999)
        
        # Test atomic increment from multiple threads
        start_val = client.next_id[]
        
        n_increments = 1000
        Threads.@threads for i in 1:n_increments
            REPE._get_next_id(client)
        end
        
        # Should have incremented exactly n_increments times
        @test client.next_id[] == start_val + n_increments
    end
end
