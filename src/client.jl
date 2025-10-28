struct PendingRequest
    channel::Channel
    result_type::Union{Nothing, Type}
end

mutable struct Client
    socket::TCPSocket
    host::String
    port::Int
    connected::Bool
    timeout::Float64
    next_id::Threads.Atomic{UInt64}
    pending_requests::Dict{UInt64, PendingRequest}
    nodelay::Bool
    
    # Synchronization primitives
    state_lock::ReentrantLock        # Protects connected and socket
    requests_lock::ReentrantLock     # Protects pending_requests
    write_lock::ReentrantLock        # Protects socket writes
    
    function Client(host::String = "localhost", port::Int = 8080; timeout::Float64 = 30.0, nodelay::Bool = true)
        new(TCPSocket(), host, port, false, timeout, 
            Threads.Atomic{UInt64}(1), 
            Dict{UInt64, PendingRequest}(),
            nodelay,
            ReentrantLock(),
            ReentrantLock(),
            ReentrantLock())
    end
end

function _resolve_addresses(host::String)::Vector{Sockets.IPAddr}
    addresses = Sockets.IPAddr[]
    for family in (Sockets.IPv6, Sockets.IPv4)
        try
            addr = Sockets.getaddrinfo(host, family)
            push!(addresses, addr)
        catch
            # Ignore resolution failures for this address family
        end
    end

    if isempty(addresses)
        try
            push!(addresses, Sockets.getaddrinfo(host))
        catch e
            error(ErrorException("Failed to resolve host $host: $(e)"))
        end
    end

    unique_addrs = Sockets.IPAddr[]
    for addr in addresses
        if !any(existing -> existing == addr, unique_addrs)
            push!(unique_addrs, addr)
        end
    end

    return unique_addrs
end

function _connect_socket(host::String, port::Int)
    last_error = nothing

    for addr in _resolve_addresses(host)
        try
            return Sockets.connect(addr, port)
        catch e
            last_error = e
        end
    end

    if last_error !== nothing
        throw(last_error)
    else
        error(ErrorException("No addresses available for host $host"))
    end
end

function connect(client::Client)
    lock(client.state_lock) do
        if client.connected
            return client
        end

        try
            client.socket = _connect_socket(client.host, client.port)
            Sockets.nodelay!(client.socket, client.nodelay)
            client.connected = true
            
            # Start the response handler
            @async _handle_responses(client)
            
            return client
        catch e
            client.connected = false
            rethrow(e)
        end
    end
end

function set_nodelay!(client::Client, enabled::Bool)
    lock(client.state_lock) do
        client.nodelay = enabled
        if client.connected
            Sockets.nodelay!(client.socket, enabled)
        end
    end
    return client
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
                for pending in values(client.pending_requests)
                    close(pending.channel)
                end
                empty!(client.pending_requests)
            end
        end
    end
end

function _get_next_id(client::Client)::UInt64
    # atomic_add! returns the old value and adds, so we get unique sequential IDs
    old_val = Threads.atomic_add!(client.next_id, UInt64(1))
    return old_val
end

function _send_message(client::Client, msg::Message)
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
        id = _get_next_id(client),
        query = method,
        body = body_bytes,
        query_format = UInt16(query_format),
        body_format = UInt16(body_format),
        notify = true
    )
    
    _send_message(client, msg)
end

# Async version that returns a Task
function send_request_async(client::Client, method::String, params = nothing; 
                           query_format::QueryFormat = QUERY_JSON_POINTER,
                           body_format::BodyFormat = BODY_JSON,
                           timeout::Union{Float64, Nothing} = nothing,
                           result_type::Union{Nothing, Type} = nothing)
    
    return @async begin
        _send_request_sync(client, method, params; 
                         query_format=query_format, 
                         body_format=body_format, 
                         timeout=timeout,
                         result_type=result_type)
    end
end

# Internal synchronous implementation
function _send_request_sync(client::Client, method::String, params = nothing; 
                          query_format::QueryFormat = QUERY_JSON_POINTER,
                          body_format::BodyFormat = BODY_JSON,
                          timeout::Union{Float64, Nothing} = nothing,
                          result_type::Union{Nothing, Type} = nothing)
    
    if !client.connected
        connect(client)
    end
    
    request_id = _get_next_id(client)
    response_channel = Channel(1)
    
    # Register the pending request
    lock(client.requests_lock) do
        client.pending_requests[request_id] = PendingRequest(response_channel, result_type)
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
        _send_message(client, msg)
        
        timeout_val = something(timeout, client.timeout)
        
        # Wait for response with timeout
        poll_interval = 0.001
        response = timedwait(timeout_val; pollint=poll_interval) do
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
                     timeout::Union{Float64, Nothing} = nothing,
                     result_type::Union{Nothing, Type} = nothing)
    
    return _send_request_sync(client, method, params; 
                            query_format=query_format, 
                            body_format=body_format, 
                            timeout=timeout,
                            result_type=result_type)
end

function send_request(::Type{T}, client::Client, method::String, params = nothing; 
                     query_format::QueryFormat = QUERY_JSON_POINTER,
                     body_format::BodyFormat = BODY_JSON,
                     timeout::Union{Float64, Nothing} = nothing) where {T}
    
    return _send_request_sync(client, method, params; 
                            query_format=query_format, 
                            body_format=body_format, 
                            timeout=timeout,
                            result_type=T)
end

function send_request_async(::Type{T}, client::Client, method::String, params = nothing; 
                           query_format::QueryFormat = QUERY_JSON_POINTER,
                           body_format::BodyFormat = BODY_JSON,
                           timeout::Union{Float64, Nothing} = nothing) where {T}
    
    return send_request_async(client, method, params; 
                             query_format=query_format, 
                             body_format=body_format, 
                             timeout=timeout,
                             result_type=T)
end

function _handle_responses(client::Client)
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
                    pending = client.pending_requests[msg.header.id]
                    ch = pending.channel
                    
                    if msg.header.ec != UInt32(EC_OK)
                        error_msg = isempty(msg.body) ? "Unknown error" : String(msg.body)
                        put!(ch, ErrorException("RPC Error ($(msg.header.ec)): $error_msg"))
                    else
                        try
                            result = pending.result_type === nothing ? 
                                parse_body(msg) : 
                                parse_body(msg, pending.result_type)
                            put!(ch, result)
                        catch parse_err
                            put!(ch, parse_err)
                        end
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
function batch(client::Client, requests::AbstractVector{<:Tuple{String, Any}}; kwargs...)
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

# Utility function to check connection status
function isconnected(client::Client)
    return client.connected
end

# Pretty printing for REPL
function Base.show(io::IO, client::Client)
    status = client.connected ? "connected" : "disconnected"
    print(io, "Client(\"$(client.host):$(client.port)\", $status)")
end
