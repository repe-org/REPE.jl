mutable struct Server
    host::String
    port::Int
    server::Union{Sockets.TCPServer, Nothing}
    running::Bool
    handlers::Dict{String, Function}
    middleware::Vector{Function}
    
    function Server(host::String = "localhost", port::Int = 8080)
        new(host, port, nothing, false, Dict{String, Function}(), Function[])
    end
end

function register(server::Server, method::String, handler::Function)
    server.handlers[method] = handler
end

function use(server::Server, middleware::Function)
    push!(server.middleware, middleware)
end

function _start_server(server::Server)
    if server.running
        return
    end
    
    server.server = Sockets.listen(Sockets.IPv4(0), server.port)
    server.running = true
    
    @info "REPE Server listening on $(server.host):$(server.port)"
    
    # Yield to allow other tasks to run
    yield()
    
    while server.running
        try
            client = accept(server.server)
            @async _handle_client(server, client)
        catch e
            if server.running
                @error "Error accepting connection" exception=e
            end
        end
    end
end

function _stop_server(server::Server)
    if !server.running
        return
    end
    
    server.running = false
    
    if server.server !== nothing
        close(server.server)
        server.server = nothing
    end
    
    @info "REPE Server stopped"
end

function _handle_client(server::Server, client::TCPSocket)
    @info "Client connected"
    
    try
        while isopen(client) && server.running
            if eof(client)
                break
            end
            
            header_bytes = read(client, HEADER_SIZE)
            if length(header_bytes) < HEADER_SIZE
                break
            end
            
            header = deserialize_header(header_bytes)
            
            message_bytes = Vector{UInt8}(undef, header.length)
            message_bytes[1:HEADER_SIZE] = header_bytes
            
            if header.query_length + header.body_length > 0
                remaining = read(client, header.query_length + header.body_length)
                message_bytes[HEADER_SIZE+1:end] = remaining
            end
            
            request = deserialize_message(message_bytes)
            
            response = _process_request(server, request)
            
            if request.header.notify == 0
                response_data = serialize_message(response)
                write(client, response_data)
                flush(client)
            end
        end
    catch e
        @error "Error handling client" exception=e
    finally
        close(client)
        @info "Client disconnected"
    end
end

function _process_request(server::Server, request::Message)::Message
    try
        for middleware in server.middleware
            result = middleware(request)
            if result !== nothing
                if result isa Message
                    return result
                elseif result isa ErrorCode
                    return _create_error_response(request, result)
                end
            end
        end
        
        method = parse_query(request)
        
        if !haskey(server.handlers, method)
            return _create_error_response(request, EC_METHOD_NOT_FOUND, 
                                        "Method not found: $method")
        end
        
        handler = server.handlers[method]
        
        params = parse_body(request)
        
        result = handler(params, request)
        
        if result isa Message
            return result
        else
            return create_response(request, result)
        end
        
    catch e
        @error "Error processing request" exception=e
        return _create_error_response(request, EC_PARSE_ERROR, string(e))
    end
end

function _create_error_response(request::Message, ec::ErrorCode, msg::String = "")::Message
    error_msg = isempty(msg) ? get(ERROR_MESSAGES, ec, "Unknown error") : msg
    
    return Message(
        id = request.header.id,
        query = request.query,
        body = error_msg,
        query_format = request.header.query_format,
        body_format = UInt16(BODY_UTF8),
        ec = UInt32(ec)
    )
end

function listen(server::Server; async::Bool = false)
    if async
        @async _start_server(server)
    else
        _start_server(server)
    end
end

