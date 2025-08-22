mutable struct Client
    socket::TCPSocket
    host::String
    port::Int
    connected::Bool
    timeout::Float64
    next_id::Threads.Atomic{UInt64}
    pending_requests::Dict{UInt64, Channel}
    
    # Synchronization primitives
    state_lock::ReentrantLock        # Protects connected and socket
    requests_lock::ReentrantLock     # Protects pending_requests
    write_lock::ReentrantLock        # Protects socket writes
    
    function Client(host::String = "localhost", port::Int = 8080; timeout::Float64 = 30.0)
        new(TCPSocket(), host, port, false, timeout, 
            Threads.Atomic{UInt64}(1), 
            Dict{UInt64, Channel}(),
            ReentrantLock(),
            ReentrantLock(),
            ReentrantLock())
    end
end

function connect(client::Client)
    lock(client.state_lock) do
        if client.connected
            return client
        end
        
        try
            client.socket = Sockets.connect(client.host, client.port)
            client.connected = true
            
            # Start the response handler
            @async handle_responses(client)
            
            return client
        catch e
            client.connected = false
            rethrow(e)
        end
    end
end

function disconnect(client::Client)
    lock(client.state_lock) do
        if !client.connected
            return
        end
        
        try
            close(client.socket)
        finally
            client.connected = false
            
            # Clean up pending requests
            lock(client.requests_lock) do
                for (_, ch) in client.pending_requests
                    close(ch)
                end
                empty!(client.pending_requests)
            end
        end
    end
end

function get_next_id(client::Client)::UInt64
    # atomic_add! returns the old value and adds, so we get unique sequential IDs
    old_val = Threads.atomic_add!(client.next_id, UInt64(1))
    return old_val
end

function send_message(client::Client, msg::Message)
    # Check connection without lock for fast path
    if !client.connected
        throw(ErrorException("Client not connected"))
    end
    
    data = serialize_message(msg)
    
    # Lock for socket write to prevent message interleaving
    lock(client.write_lock) do
        write(client.socket, data)
        flush(client.socket)
    end
end

function send_notify(client::Client, method::String, params = nothing; 
                    query_format::QueryFormat = QUERY_JSON_POINTER,
                    body_format::BodyFormat = BODY_JSON)
    
    body_bytes = params === nothing ? UInt8[] : encode_body(params, body_format)
    
    msg = Message(
        id = get_next_id(client),
        query = method,
        body = body_bytes,
        query_format = UInt16(query_format),
        body_format = UInt16(body_format),
        notify = true
    )
    
    send_message(client, msg)
end

# Async version that returns a Task
function send_request_async(client::Client, method::String, params = nothing; 
                           query_format::QueryFormat = QUERY_JSON_POINTER,
                           body_format::BodyFormat = BODY_JSON,
                           timeout::Union{Float64, Nothing} = nothing)
    
    return @async begin
        send_request_sync(client, method, params; 
                         query_format=query_format, 
                         body_format=body_format, 
                         timeout=timeout)
    end
end

# Internal synchronous implementation
function send_request_sync(client::Client, method::String, params = nothing; 
                          query_format::QueryFormat = QUERY_JSON_POINTER,
                          body_format::BodyFormat = BODY_JSON,
                          timeout::Union{Float64, Nothing} = nothing)
    
    if !client.connected
        connect(client)
    end
    
    request_id = get_next_id(client)
    response_channel = Channel(1)
    
    # Register the pending request
    lock(client.requests_lock) do
        client.pending_requests[request_id] = response_channel
    end
    
    body_bytes = params === nothing ? UInt8[] : encode_body(params, body_format)
    
    msg = Message(
        id = request_id,
        query = method,
        body = body_bytes,
        query_format = UInt16(query_format),
        body_format = UInt16(body_format),
        notify = false
    )
    
    try
        send_message(client, msg)
        
        timeout_val = something(timeout, client.timeout)
        
        # Wait for response with timeout
        response = timedwait(timeout_val) do
            isready(response_channel)
        end
        
        if response == :timed_out
            # Clean up on timeout
            lock(client.requests_lock) do
                delete!(client.pending_requests, request_id)
            end
            close(response_channel)
            throw(ErrorException("Request timed out"))
        end
        
        result = take!(response_channel)
        
        # Clean up after receiving response
        lock(client.requests_lock) do
            delete!(client.pending_requests, request_id)
        end
        
        if result isa Exception
            throw(result)
        end
        
        return result
        
    catch e
        # Clean up on error
        lock(client.requests_lock) do
            delete!(client.pending_requests, request_id)
        end
        close(response_channel)
        rethrow(e)
    end
end

# Backward compatible synchronous version
function send_request(client::Client, method::String, params = nothing; 
                     query_format::QueryFormat = QUERY_JSON_POINTER,
                     body_format::BodyFormat = BODY_JSON,
                     timeout::Union{Float64, Nothing} = nothing)
    
    return send_request_sync(client, method, params; 
                            query_format=query_format, 
                            body_format=body_format, 
                            timeout=timeout)
end

function handle_responses(client::Client)
    buffer = UInt8[]
    
    while true
        # Check if still connected (with lock)
        connected = lock(client.state_lock) do
            client.connected
        end
        
        if !connected
            break
        end
        
        try
            if eof(client.socket)
                break
            end
            
            # Read header
            header_bytes = read(client.socket, HEADER_SIZE)
            if length(header_bytes) < HEADER_SIZE
                break
            end
            
            header = deserialize_header(header_bytes)
            
            # Read complete message
            message_bytes = Vector{UInt8}(undef, header.length)
            message_bytes[1:HEADER_SIZE] = header_bytes
            
            if header.query_length + header.body_length > 0
                remaining = read(client.socket, header.query_length + header.body_length)
                message_bytes[HEADER_SIZE+1:end] = remaining
            end
            
            msg = deserialize_message(message_bytes)
            
            # Find and notify the waiting request
            lock(client.requests_lock) do
                if haskey(client.pending_requests, msg.header.id)
                    ch = client.pending_requests[msg.header.id]
                    
                    if msg.header.ec != UInt32(EC_OK)
                        error_msg = isempty(msg.body) ? "Unknown error" : String(msg.body)
                        put!(ch, ErrorException("RPC Error ($(msg.header.ec)): $error_msg"))
                    else
                        result = parse_body(msg)
                        put!(ch, result)
                    end
                end
            end
            
        catch e
            # Check if we should continue
            connected = lock(client.state_lock) do
                client.connected
            end
            
            if !connected
                break
            end
            @warn "Error handling response" exception=e
        end
    end
    
    # Mark as disconnected
    lock(client.state_lock) do
        client.connected = false
    end
end

# Convenience function for concurrent batch requests
function batch(client::Client, requests::Vector{Tuple{String, Any}}; kwargs...)
    tasks = Task[]
    for (method, params) in requests
        task = send_request_async(client, method, params; kwargs...)
        push!(tasks, task)
    end
    return tasks
end

# Wait for all tasks and collect results
function await_batch(tasks::Vector{Task})
    return [fetch(task) for task in tasks]
end

function call_method(client::Client, method::String, args...; kwargs...)
    params = isempty(args) ? nothing : length(args) == 1 ? args[1] : args
    return send_request(client, method, params; kwargs...)
end

macro rpc(client, method, args...)
    esc(quote
        call_method($client, $(string(method)), $(args...))
    end)
end