# UniUDP Fleet API - Multi-server control for unidirectional UDP
# Provides unified interface for broadcasting to multiple UniUDP endpoints

using Base.Threads: ReentrantLock

#==============================================================================#
# Types
#==============================================================================#

"""
    UniUDPNodeConfig

Configuration for a UniUDP target endpoint.

# Example
```julia
# Simple configuration
UniUDPNodeConfig("sensor-gateway.local", 5000)

# With reliability settings
UniUDPNodeConfig("satellite-uplink.local", 5000;
    redundancy = 3,        # Triple redundancy for lossy link
    fec_group_size = 4,    # XOR parity every 4 chunks
    tags = ["uplink", "critical"]
)
```
"""
struct UniUDPNodeConfig
    name::String
    host::String
    port::Int
    tags::Vector{String}
    redundancy::Int
    chunk_size::Int
    fec_group_size::Int

    function UniUDPNodeConfig(host::String, port::Int;
                              name::String = host,
                              tags::Vector{String} = String[],
                              redundancy::Int = 1,
                              chunk_size::Int = 1024,
                              fec_group_size::Int = 4)
        (port < 1 || port > 65535) && throw(ArgumentError("port must be between 1 and 65535"))
        redundancy < 1 && throw(ArgumentError("redundancy must be at least 1"))
        chunk_size < 1 && throw(ArgumentError("chunk_size must be positive"))
        fec_group_size < 1 && throw(ArgumentError("fec_group_size must be at least 1"))
        new(name, host, port, tags, redundancy, chunk_size, fec_group_size)
    end
end

"""
    UniUDPNode

Internal representation of a UniUDP target.
"""
mutable struct UniUDPNode
    name::String
    host::String
    port::Int
    tags::Set{String}
    config::UniUDPNodeConfig
    client::UniUDPClient

    function UniUDPNode(config::UniUDPNodeConfig)
        client = UniUDPClient(config.host, config.port;
                              redundancy=config.redundancy,
                              chunk_size=config.chunk_size,
                              fec_group_size=config.fec_group_size)
        new(config.name, config.host, config.port, Set(config.tags), config, client)
    end
end

"""
    SendResult

Result from a UniUDP send operation.

# Fields
- `node::String` - Target node name
- `message_id::UInt64` - UniUDP message ID (always set)
- `error::Union{Exception, Nothing}` - Exception (nothing on success)
- `elapsed::Float64` - Time taken in seconds
"""
struct SendResult
    node::String
    message_id::UInt64
    error::Union{Exception, Nothing}
    elapsed::Float64
end

"""
    succeeded(r::SendResult) -> Bool

Check if the send succeeded (no error).
"""
succeeded(r::SendResult) = r.error === nothing

"""
    failed(r::SendResult) -> Bool

Check if the send failed (has error).
"""
failed(r::SendResult) = r.error !== nothing

"""
    UniUDPFleet

Fleet interface optimized for unidirectional UDP broadcasting.

# Example
```julia
config = [
    UniUDPNodeConfig("gateway-1.local", 5000; tags=["primary"]),
    UniUDPNodeConfig("gateway-2.local", 5000; tags=["backup"]),
]

fleet = UniUDPFleet(config)

# Broadcast notification to all nodes
results = send_notify(fleet, "/sensor/reading", Dict("value" => 23.5))

# Filter by tag
results = send_notify(fleet, "/alert", Dict("level" => "warning"); tags=["primary"])

close(fleet)
```
"""
mutable struct UniUDPFleet
    nodes::Dict{String, UniUDPNode}
    nodes_lock::ReentrantLock

    function UniUDPFleet(configs::Vector{UniUDPNodeConfig})
        # Check for duplicate names BEFORE creating any nodes
        # (to provide clear error messages before network errors)
        seen_names = Set{String}()
        for config in configs
            if config.name in seen_names
                throw(ArgumentError("Duplicate node name: \"$(config.name)\". Multiple endpoints on the same host require explicit unique names."))
            end
            push!(seen_names, config.name)
        end

        # Now create nodes
        nodes = Dict{String, UniUDPNode}()
        for config in configs
            nodes[config.name] = UniUDPNode(config)
        end

        new(nodes, ReentrantLock())
    end
end

# Empty fleet constructor
UniUDPFleet() = UniUDPFleet(UniUDPNodeConfig[])

#==============================================================================#
# Node Access
#==============================================================================#

"""
    nodes(fleet::UniUDPFleet) -> Vector{UniUDPNode}

Get all nodes in the fleet.
"""
function nodes(fleet::UniUDPFleet)
    lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end
end

"""
    filter_nodes(fleet::UniUDPFleet; tags::Vector{String}) -> Vector{UniUDPNode}

Get nodes matching all specified tags.
"""
function filter_nodes(fleet::UniUDPFleet; tags::Vector{String})
    tag_set = Set(tags)
    lock(fleet.nodes_lock) do
        [node for node in values(fleet.nodes) if tag_set ⊆ node.tags]
    end
end

"""
    Base.getindex(fleet::UniUDPFleet, name::String) -> UniUDPNode

Get a node by name.
"""
function Base.getindex(fleet::UniUDPFleet, name::String)
    lock(fleet.nodes_lock) do
        if !haskey(fleet.nodes, name)
            throw(KeyError(name))
        end
        return fleet.nodes[name]
    end
end

"""
    Base.length(fleet::UniUDPFleet) -> Int

Get the number of nodes in the fleet.
"""
function Base.length(fleet::UniUDPFleet)
    lock(fleet.nodes_lock) do
        length(fleet.nodes)
    end
end

"""
    Base.keys(fleet::UniUDPFleet) -> Vector{String}

Get all node names in the fleet.
"""
function Base.keys(fleet::UniUDPFleet)
    lock(fleet.nodes_lock) do
        collect(keys(fleet.nodes))
    end
end

#==============================================================================#
# Dynamic Node Management
#==============================================================================#

"""
    add_node!(fleet::UniUDPFleet, config::UniUDPNodeConfig) -> UniUDPFleet

Add a new node to the fleet. Throws `ArgumentError` if a node with the same name already exists.
"""
function add_node!(fleet::UniUDPFleet, config::UniUDPNodeConfig)
    lock(fleet.nodes_lock) do
        if haskey(fleet.nodes, config.name)
            throw(ArgumentError("Node \"$(config.name)\" already exists in fleet"))
        end
        fleet.nodes[config.name] = UniUDPNode(config)
    end
    return fleet
end

"""
    remove_node!(fleet::UniUDPFleet, name::String) -> UniUDPFleet

Remove a node from the fleet. Closes the client socket.
"""
function remove_node!(fleet::UniUDPFleet, name::String)
    lock(fleet.nodes_lock) do
        if haskey(fleet.nodes, name)
            node = fleet.nodes[name]
            try
                close(node.client)
            catch
                # Ignore close errors during removal
            end
            delete!(fleet.nodes, name)
        end
    end
    return fleet
end

"""
    Base.close(fleet::UniUDPFleet)

Close all client sockets in the fleet.
"""
function Base.close(fleet::UniUDPFleet)
    lock(fleet.nodes_lock) do
        for node in values(fleet.nodes)
            try
                close(node.client)
            catch
                # Ignore close errors
            end
        end
    end
end

#==============================================================================#
# Send Operations
#==============================================================================#

"""
    send_notify(fleet::UniUDPFleet, method::String, params=nothing; tags=String[], kwargs...) -> Dict{String, SendResult}

Broadcast a notification to all matching nodes (fire-and-forget).

# Arguments
- `fleet`: The UniUDP fleet
- `method`: The RPC method name
- `params`: Optional parameters

# Keyword Arguments
- `tags`: Filter nodes by tags (empty means all nodes)
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)
"""
function send_notify(fleet::UniUDPFleet, method::String, params=nothing;
                     tags::Vector{String} = String[],
                     query_format::QueryFormat = QUERY_JSON_POINTER,
                     body_format::BodyFormat = BODY_JSON)

    # Snapshot nodes under lock
    target_nodes = lock(fleet.nodes_lock) do
        if isempty(tags)
            collect(values(fleet.nodes))
        else
            tag_set = Set(tags)
            [node for node in values(fleet.nodes) if tag_set ⊆ node.tags]
        end
    end

    # Send in parallel
    results = Dict{String, SendResult}()
    tasks = Dict{String, Task}()

    for node in target_nodes
        tasks[node.name] = @async begin
            start_time = time()
            try
                msg_id = send_notify(node.client, method, params;
                                     query_format=query_format,
                                     body_format=body_format)
                elapsed = time() - start_time
                return SendResult(node.name, msg_id, nothing, elapsed)
            catch e
                elapsed = time() - start_time
                return SendResult(node.name, UInt64(0), e, elapsed)
            end
        end
    end

    # Collect results
    for (name, task) in tasks
        results[name] = fetch(task)
    end

    return results
end

"""
    send_request(fleet::UniUDPFleet, method::String, params=nothing; tags=String[], kwargs...) -> Dict{String, SendResult}

Broadcast a request to all matching nodes (fire-and-forget, since UniUDP is unidirectional).

# Arguments
- `fleet`: The UniUDP fleet
- `method`: The RPC method name
- `params`: Optional parameters

# Keyword Arguments
- `tags`: Filter nodes by tags (empty means all nodes)
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)
"""
function send_request(fleet::UniUDPFleet, method::String, params=nothing;
                      tags::Vector{String} = String[],
                      query_format::QueryFormat = QUERY_JSON_POINTER,
                      body_format::BodyFormat = BODY_JSON)

    # Snapshot nodes under lock
    target_nodes = lock(fleet.nodes_lock) do
        if isempty(tags)
            collect(values(fleet.nodes))
        else
            tag_set = Set(tags)
            [node for node in values(fleet.nodes) if tag_set ⊆ node.tags]
        end
    end

    # Send in parallel
    results = Dict{String, SendResult}()
    tasks = Dict{String, Task}()

    for node in target_nodes
        tasks[node.name] = @async begin
            start_time = time()
            try
                msg_id = send_request(node.client, method, params;
                                      query_format=query_format,
                                      body_format=body_format)
                elapsed = time() - start_time
                return SendResult(node.name, msg_id, nothing, elapsed)
            catch e
                elapsed = time() - start_time
                return SendResult(node.name, UInt64(0), e, elapsed)
            end
        end
    end

    # Collect results
    for (name, task) in tasks
        results[name] = fetch(task)
    end

    return results
end

"""
    notify_all(fleet::UniUDPFleet, method::String, params=nothing; kwargs...) -> Dict{String, SendResult}

Notify all nodes (no filtering). Convenience alias for `send_notify` without tags.
"""
function notify_all(fleet::UniUDPFleet, method::String, params=nothing;
                    query_format::QueryFormat = QUERY_JSON_POINTER,
                    body_format::BodyFormat = BODY_JSON)
    send_notify(fleet, method, params; tags=String[], query_format=query_format, body_format=body_format)
end

#==============================================================================#
# Callable Syntax
#==============================================================================#

"""
    (fleet::UniUDPFleet)(method::String, params=nothing; tags=String[], kwargs...)

Callable broadcast syntax. Equivalent to `send_notify(fleet, method, params; tags=tags, kwargs...)`.
"""
function (fleet::UniUDPFleet)(method::String, params=nothing;
                              tags::Vector{String} = String[],
                              query_format::QueryFormat = QUERY_JSON_POINTER,
                              body_format::BodyFormat = BODY_JSON)
    send_notify(fleet, method, params; tags=tags, query_format=query_format, body_format=body_format)
end

"""
    (fleet::UniUDPFleet)(node_name::String, method::String, params; kwargs...)

Callable single-node syntax. Sends to a specific node.
"""
function (fleet::UniUDPFleet)(node_name::String, method::String, params;
                              query_format::QueryFormat = QUERY_JSON_POINTER,
                              body_format::BodyFormat = BODY_JSON)

    node = lock(fleet.nodes_lock) do
        if !haskey(fleet.nodes, node_name)
            throw(KeyError(node_name))
        end
        fleet.nodes[node_name]
    end

    start_time = time()
    try
        msg_id = send_notify(node.client, method, params;
                             query_format=query_format,
                             body_format=body_format)
        elapsed = time() - start_time
        return SendResult(node.name, msg_id, nothing, elapsed)
    catch e
        elapsed = time() - start_time
        return SendResult(node.name, UInt64(0), e, elapsed)
    end
end

#==============================================================================#
# Pretty Printing
#==============================================================================#

function Base.show(io::IO, config::UniUDPNodeConfig)
    print(io, "UniUDPNodeConfig(\"$(config.host)\", $(config.port)")
    if config.name != config.host
        print(io, "; name=\"$(config.name)\"")
    end
    if !isempty(config.tags)
        print(io, ", tags=$(config.tags)")
    end
    if config.redundancy != 1
        print(io, ", redundancy=$(config.redundancy)")
    end
    print(io, ")")
end

function Base.show(io::IO, node::UniUDPNode)
    status = isopen(node.client) ? "open" : "closed"
    print(io, "UniUDPNode(\"$(node.name)\", $(node.host):$(node.port), $status)")
end

function Base.show(io::IO, fleet::UniUDPFleet)
    n = length(fleet)
    print(io, "UniUDPFleet($n nodes)")
end

function Base.show(io::IO, r::SendResult)
    if succeeded(r)
        print(io, "SendResult($(r.node), msg_id=$(r.message_id), $(round(r.elapsed * 1000, digits=1))ms)")
    else
        print(io, "SendResult($(r.node), failed: $(typeof(r.error)), $(round(r.elapsed * 1000, digits=1))ms)")
    end
end
