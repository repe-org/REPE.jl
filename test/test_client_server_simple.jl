@testset "Simple Client-Server Tests" begin
    @testset "Message Round-trip" begin
        # Test that a message can be serialized and deserialized correctly
        request = REPE.Message(
            id = 123,
            query = "/test/method",
            body = Dict("param" => "value"),
            body_format = UInt16(REPE.BODY_JSON)
        )
        
        bytes = serialize_message(request)
        response = deserialize_message(bytes)
        
        @test response.header.id == request.header.id
        @test String(response.query) == String(request.query)
        @test response.header.body_format == request.header.body_format
    end
    
    @testset "Handler Registration" begin
        server = REPE.Server("localhost", 9999)
        
        handler_called = Ref(false)
        REPE.register(server, "/test", function(params, request)
            handler_called[] = true
            return Dict("result" => "ok")
        end)
        
        @test haskey(server.handlers, "/test")
        
        # Simulate processing a request
        request = REPE.Message(
            id = 456,
            query = "/test",
            body = Dict("data" => "test"),
            body_format = UInt16(REPE.BODY_JSON)
        )
        
        response = REPE._process_request(server, request)
        @test handler_called[] == true
        @test response.header.id == 456
        @test response.header.ec == UInt32(REPE.EC_OK)
    end
    
    @testset "Error Response" begin
        server = REPE.Server("localhost", 9998)
        
        # Request to non-existent handler
        request = REPE.Message(
            id = 789,
            query = "/nonexistent",
            body = "",
            body_format = UInt16(REPE.BODY_UTF8)
        )
        
        response = REPE._process_request(server, request)
        @test response.header.id == 789
        @test response.header.ec == UInt32(REPE.EC_METHOD_NOT_FOUND)
        @test occursin("not found", String(response.body))
    end
    
    @testset "Middleware" begin
        server = REPE.Server("localhost", 9997)
        
        middleware_called = Ref(false)
        REPE.use(server, function(request)
            middleware_called[] = true
            return nothing  # Continue processing
        end)
        
        REPE.register(server, "/test", function(params, request)
            return Dict("result" => "ok")
        end)
        
        request = REPE.Message(
            id = 101,
            query = "/test",
            body = "",
            body_format = UInt16(REPE.BODY_UTF8)
        )
        
        response = REPE._process_request(server, request)
        @test middleware_called[] == true
        @test response.header.ec == UInt32(REPE.EC_OK)
    end
end