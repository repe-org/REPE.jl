# UniUDP Server - REPE server over unidirectional UDP

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
using REPE

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
function register(server::UniUDPServer, method::String, handler::Function)
    server.handlers[method] = handler
end

# Support do-block syntax
function register(handler::Function, server::UniUDPServer, method::String)
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
        @async _serve_uniudp_loop(server)
    else
        _serve_uniudp_loop(server)
    end
end

function _serve_uniudp_loop(server::UniUDPServer)
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
            if length(report.payload) < HEADER_SIZE
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
function stop(server::UniUDPServer)
    server.running[] = false
end

"""
    listen(server::UniUDPServer; async::Bool=false)

Start the UniUDP server, processing incoming messages until stopped.
This is an alias for `serve()` to match the TCP server API.
"""
function listen(server::UniUDPServer; async::Bool=false)
    serve(server; async=async)
end

"""
    close(server::UniUDPServer)

Stop the server and close its UDP socket.
"""
function Base.close(server::UniUDPServer)
    stop(server)
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
function Base.show(io::IO, server::UniUDPServer)
    status = server.running[] ? "running" : "stopped"
    n_handlers = length(server.handlers)
    handler_text = n_handlers == 1 ? "1 handler" : "$n_handlers handlers"
    print(io, "UniUDPServer($status, $handler_text)")
end
