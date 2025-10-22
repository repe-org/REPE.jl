@testset "Client-Server Tests" begin
    @testset "Basic RPC" begin
        port = 9001
        server = REPE.Server("localhost", port)
        
        REPE.register(server, "/add", function(params, request)
            result = params["a"] + params["b"]
            return Dict("result" => result)
        end)
        
        REPE.register(server, "/echo", function(params, request)
            return params
        end)
        
        # Start server in background and wait for it to be ready
        REPE.listen(server; async=true)
        REPE.wait_for_server(server.host, port)
        
        client = REPE.Client("localhost", port)
        REPE.connect(client)
        
        try
            result = REPE.send_request(client, "/add", Dict("a" => 5, "b" => 3))
            @test result["result"] == 8
            
            echo_result = REPE.send_request(client, "/echo", "Hello, REPE!")
            @test echo_result == "Hello, REPE!"
            
        finally
            REPE.disconnect(client)
            REPE.stop(server)
        end
    end
    
    @testset "Error Handling" begin
        port = 9002
        server = REPE.Server("localhost", port)
        
        REPE.register(server, "/divide", function(params, request)
            if params["b"] == 0
                throw(ErrorException("Division by zero"))
            end
            return Dict("result" => params["a"] / params["b"])
        end)
        
        # Start server in background and wait for it to be ready
        REPE.listen(server; async=true)
        REPE.wait_for_server(server.host, port)
        
        client = REPE.Client("localhost", port)
        REPE.connect(client)
        
        try
            result = REPE.send_request(client, "/divide", Dict("a" => 10, "b" => 2))
            @test result["result"] == 5.0
            
            @test_throws Exception REPE.send_request(client, "/nonexistent", Dict())
            
        finally
            REPE.disconnect(client)
            REPE.stop(server)
        end
    end
    
    @testset "Notifications" begin
        port = 9003
        server = REPE.Server("localhost", port)
        
        received = Ref(false)
        REPE.register(server, "/notify", function(params, request)
            received[] = true
            return Dict("status" => "received")
        end)
        
        # Start server in background and wait for it to be ready
        REPE.listen(server; async=true)
        REPE.wait_for_server(server.host, port)
        
        client = REPE.Client("localhost", port)
        REPE.connect(client)
        
        try
            REPE.send_notify(client, "/notify", Dict("message" => "test"))
            sleep(1.0)
            @test received[] == true
            
        finally
            REPE.disconnect(client)
            REPE.stop(server)
        end
    end
    
    @testset "Different Formats" begin
        port = 9004
        server = REPE.Server("localhost", port)
        
        REPE.register(server, "/process", function(params, request)
            if request.header.body_format == UInt16(REPE.BODY_JSON)
                return Dict("format" => "json", "data" => params)
            elseif request.header.body_format == UInt16(REPE.BODY_UTF8)
                return "Received text: $params"
            else
                return params
            end
        end)
        
        # Start server in background and wait for it to be ready
        REPE.listen(server; async=true)
        REPE.wait_for_server(server.host, port)
        
        client = REPE.Client("localhost", port)
        REPE.connect(client)
        
        try
            json_result = REPE.send_request(client, "/process", 
                                           Dict("test" => true),
                                           body_format = REPE.BODY_JSON)
            @test json_result["format"] == "json"
            
            text_result = REPE.send_request(client, "/process",
                                           "Hello",
                                           body_format = REPE.BODY_UTF8)
            @test occursin("Received text", text_result)
            
        finally
            REPE.disconnect(client)
            REPE.stop(server)
        end
    end

    @testset "Typed Responses" begin
        struct TypedResponse
            answer::Int
            message::String
        end

        port = 9005
        server = REPE.Server("localhost", port)

        REPE.register(server, "/typed", function(params, request)
            return Dict("answer" => 42, "message" => "life")
        end)

        REPE.register(server, "/typed_beve", function(params, request)
            result = Dict("answer" => 24, "message" => "beve")
            return REPE.create_response(request, result; body_format = REPE.BODY_BEVE)
        end)

        REPE.listen(server; async=true)
        REPE.wait_for_server(server.host, port)

        client = REPE.Client("localhost", port)
        REPE.connect(client)

        try
            typed_result = REPE.send_request(TypedResponse, client, "/typed", Dict())
            @test typed_result isa TypedResponse
            @test typed_result.answer == 42
            @test typed_result.message == "life"

            keyword_result = REPE.send_request(client, "/typed", Dict(); result_type=TypedResponse)
            @test keyword_result isa TypedResponse

            task_json = REPE.send_request_async(TypedResponse, client, "/typed", Dict())
            async_json_result = fetch(task_json)
            @test async_json_result isa TypedResponse

            beve_result = REPE.send_request(TypedResponse, client, "/typed_beve", Dict())
            @test beve_result isa TypedResponse
            @test beve_result.answer == 24
            @test beve_result.message == "beve"

            beve_keyword = REPE.send_request(client, "/typed_beve", Dict(); result_type = TypedResponse)
            @test beve_keyword isa TypedResponse

            task_beve = REPE.send_request_async(client, "/typed_beve", Dict(); result_type = TypedResponse)
            async_beve_result = fetch(task_beve)
            @test async_beve_result isa TypedResponse
        finally
            REPE.disconnect(client)
            REPE.stop(server)
        end
    end
end
