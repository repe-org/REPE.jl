# UniUDP Client - REPE client over unidirectional UDP

"""
    UniUDPClient

A REPE client that sends messages over UniUDP (unidirectional UDP).
Supports both notifications (fire-and-forget) and requests (fire-and-forget,
since no response path exists over one-way UDP).

# Example
```julia
using REPE

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
        fec_group_size::Int = 4,
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

function _send_uniudp_message(client::UniUDPClient, msg::Message)
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
function send_notify(client::UniUDPClient, method::String, params=nothing;
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

    _send_uniudp_message(client, msg)
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
function send_request(client::UniUDPClient, method::String, params=nothing;
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

    _send_uniudp_message(client, msg)
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

# Pretty printing
function Base.show(io::IO, client::UniUDPClient)
    status = isopen(client.socket) ? "open" : "closed"
    print(io, "UniUDPClient($(client.target_host):$(client.target_port), ",
          "redundancy=$(client.redundancy), fec=$(client.fec_group_size), $status)")
end
