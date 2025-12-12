module UniUDPExt

using REPE
using UniUDP
using Sockets

import REPE: parse_query, parse_body, encode_body, serialize_message, deserialize_message,
             Message, QueryFormat, BodyFormat, QUERY_JSON_POINTER, BODY_JSON, EC_OK

"""
    UniUDPClient

A REPE client that sends messages over UniUDP (unidirectional UDP).
Supports both notifications (fire-and-forget) and requests (fire-and-forget,
since no response path exists over one-way UDP).

# Example
```julia
using REPE, UniUDP

client = UniUDPClient(ip"192.168.1.100", 5000; redundancy=2)

# Fire-and-forget notification
send_notify(client, "/sensor/temperature", Dict("value" => 23.5))

# Fire-and-forget request (server computes result but can't return it)
send_request(client, "/compute/factorial", Dict("n" => 10))

close(client)
```
"""
struct UniUDPClient
    socket::UDPSocket
    target_host::Sockets.IPAddr
    target_port::Int
    redundancy::Int
    chunk_size::Int
    fec_group_size::Int
    next_id::Threads.Atomic{UInt64}

    function UniUDPClient(
        host::Union{String, Sockets.IPAddr},
        port::Int;
        redundancy::Int = 1,
        chunk_size::Int = 1024,
        fec_group_size::Int = 1,
        bind_addr::Sockets.IPAddr = ip"0.0.0.0",
        bind_port::Int = 0
    )
        socket = UDPSocket()
        bind(socket, bind_addr, bind_port)

        target_host = host isa String ? Sockets.getaddrinfo(host) : host

        new(socket, target_host, port, redundancy, chunk_size, fec_group_size,
            Threads.Atomic{UInt64}(1))
    end
end

function _get_next_id(client::UniUDPClient)::UInt64
    return Threads.atomic_add!(client.next_id, UInt64(1))
end

function _send_message(client::UniUDPClient, msg::Message)
    data = serialize_message(msg)
    UniUDP.send_message(
        client.socket,
        client.target_host,
        client.target_port,
        data;
        redundancy = client.redundancy,
        chunk_size = client.chunk_size,
        fec_group_size = client.fec_group_size
    )
end

"""
    send_notify(client::UniUDPClient, method::String, params=nothing; kwargs...)

Send a fire-and-forget notification over UniUDP. No response is expected.

# Arguments
- `client`: The UniUDP client
- `method`: The RPC method name (e.g., "/sensor/temperature")
- `params`: Optional parameters to send (will be serialized according to body_format)
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)

# Returns
The REPE message ID used for the transmission.
"""
function REPE.send_notify(client::UniUDPClient, method::String, params=nothing;
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
    return msg.header.id
end

"""
    send_request(client::UniUDPClient, method::String, params=nothing; kwargs...)

Send a request over UniUDP. Since UDP is unidirectional, no response will be
received. The server will process the request and invoke its response_callback
with the computed result.

This is useful when you want the server to perform a computation and handle
the result locally (e.g., log it, store it, display it).

# Arguments
- `client`: The UniUDP client
- `method`: The RPC method name (e.g., "/compute/factorial")
- `params`: Optional parameters to send
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)

# Returns
The REPE message ID used for the transmission.
"""
function REPE.send_request(client::UniUDPClient, method::String, params=nothing;
                           query_format::QueryFormat = QUERY_JSON_POINTER,
                           body_format::BodyFormat = BODY_JSON)

    body_bytes = params === nothing ? UInt8[] : encode_body(params, body_format)

    msg = Message(
        id = _get_next_id(client),
        query = method,
        body = body_bytes,
        query_format = UInt16(query_format),
        body_format = UInt16(body_format),
        notify = false
    )

    _send_message(client, msg)
    return msg.header.id
end

"""
    close(client::UniUDPClient)

Close the UDP socket associated with this client.
"""
function Base.close(client::UniUDPClient)
    close(client.socket)
end

"""
    isopen(client::UniUDPClient)

Check if the client's socket is still open.
"""
function Base.isopen(client::UniUDPClient)
    isopen(client.socket)
end

# Default response callback - does nothing
_default_response_callback(method, result, msg) = nothing

"""
    UniUDPServer

A REPE server that receives messages over UniUDP (unidirectional UDP).
Handles both notifications and requests. Since responses cannot be sent back
over one-way UDP, computed results from requests are passed to a configurable
`response_callback`.

# Example
```julia
using REPE, UniUDP

server = UniUDPServer(5000;
    response_callback = (method, result, msg) -> println("Result of \$method: \$result")
)

register(server, "/compute/square") do params, msg
    return params["x"]^2  # Result goes to response_callback
end

register(server, "/sensor/reading") do params, msg
    println("Received: \$params")  # Notification, no result expected
end

listen(server)
```
"""
mutable struct UniUDPServer
    socket::UDPSocket
    handlers::Dict{String,Function}
    running::Ref{Bool}
    inactivity_timeout::Float64
    overall_timeout::Float64
    response_callback::Function

    function UniUDPServer(
        port::Int;
        host::Union{String, Sockets.IPAddr} = ip"0.0.0.0",
        inactivity_timeout::Float64 = 0.5,
        overall_timeout::Float64 = 30.0,
        response_callback::Function = _default_response_callback
    )
        socket = UDPSocket()
        bind_addr = host isa String ? Sockets.getaddrinfo(host) : host
        bind(socket, bind_addr, port)

        new(socket, Dict{String,Function}(), Ref(false),
            inactivity_timeout, overall_timeout, response_callback)
    end
end

"""
    register(server::UniUDPServer, method::String, handler::Function)
    register(handler::Function, server::UniUDPServer, method::String)

Register a handler function for a specific method.
The handler receives `(params, message)` arguments where:
- `params`: The deserialized body of the message (or `nothing` if empty)
- `message`: The full REPE Message struct

For notifications, the return value is ignored.
For requests, the return value is passed to the server's `response_callback`.

# Example
```julia
register(server, "/compute/double") do params, msg
    return params["value"] * 2
end
```
"""
function REPE.register(server::UniUDPServer, method::String, handler::Function)
    server.handlers[method] = handler
end

# Support do-block syntax
function REPE.register(handler::Function, server::UniUDPServer, method::String)
    server.handlers[method] = handler
end

"""
    serve(server::UniUDPServer; async::Bool=false)

Start the server loop, processing incoming messages until stopped.

If `async=true`, runs in a background task and returns immediately.
Otherwise blocks until `stop(server)` is called.
"""
function serve(server::UniUDPServer; async::Bool=false)
    if async
        @async _serve_loop(server)
    else
        _serve_loop(server)
    end
end

function _serve_loop(server::UniUDPServer)
    server.running[] = true
    @info "UniUDP REPE Server listening"

    while server.running[]
        try
            report = UniUDP.receive_message(
                server.socket;
                inactivity_timeout = server.inactivity_timeout,
                overall_timeout = server.overall_timeout
            )

            # Check for incomplete message
            if !isempty(report.lost_chunks)
                @warn "Incomplete REPE message received" lost=length(report.lost_chunks) total=report.chunks_expected
                continue
            end

            # Check payload is large enough for REPE header
            if length(report.payload) < REPE.HEADER_SIZE
                @warn "Payload too small for REPE message" size=length(report.payload)
                continue
            end

            # Deserialize REPE message
            msg = deserialize_message(report.payload)

            # Get method name
            method = parse_query(msg)

            # Find handler
            handler = get(server.handlers, method, nothing)
            if handler === nothing
                @warn "No handler for method" method=method
                continue
            end

            # Parse params and call handler
            params = parse_body(msg)
            result = handler(params, msg)

            # For non-notify requests, invoke the response callback
            # Use invokelatest to handle callback mutations after server start (world age issues)
            if msg.header.notify == 0x00 && result !== nothing
                try
                    Base.invokelatest(server.response_callback, method, result, msg)
                catch cb_err
                    @warn "Response callback error" method=method exception=(cb_err, catch_backtrace())
                end
            end

        catch e
            if server.running[]
                if isa(e, ErrorException) && contains(string(e), "timeout")
                    # Timeouts are expected during quiet periods, don't warn
                    continue
                end
                @warn "Error processing message" exception=(e, catch_backtrace())
            end
        end
    end

    @info "UniUDP REPE Server stopped"
end

"""
    stop(server::UniUDPServer)

Stop the server loop. The server will finish processing the current message
and then exit the serve loop.
"""
function REPE.stop(server::UniUDPServer)
    server.running[] = false
end

"""
    listen(server::UniUDPServer; async::Bool=false)

Start the UniUDP server, processing incoming messages until stopped.
This is an alias for `serve()` to match the TCP server API.
"""
function REPE.listen(server::UniUDPServer; async::Bool=false)
    serve(server; async=async)
end

"""
    close(server::UniUDPServer)

Stop the server and close its UDP socket.
"""
function Base.close(server::UniUDPServer)
    REPE.stop(server)
    close(server.socket)
end

"""
    isopen(server::UniUDPServer)

Check if the server's socket is still open.
"""
function Base.isopen(server::UniUDPServer)
    isopen(server.socket)
end

# Pretty printing
function Base.show(io::IO, client::UniUDPClient)
    status = isopen(client.socket) ? "open" : "closed"
    print(io, "UniUDPClient($(client.target_host):$(client.target_port), ",
          "redundancy=$(client.redundancy), fec=$(client.fec_group_size), $status)")
end

function Base.show(io::IO, server::UniUDPServer)
    status = server.running[] ? "running" : "stopped"
    n_handlers = length(server.handlers)
    handler_text = n_handlers == 1 ? "1 handler" : "$n_handlers handlers"
    print(io, "UniUDPServer($status, $handler_text)")
end

# Populate REPE module with actual types when extension loads
function __init__()
    REPE.eval(:(global UniUDPClient = $UniUDPClient))
    REPE.eval(:(global UniUDPServer = $UniUDPServer))
end

end # module
