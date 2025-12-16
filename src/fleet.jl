# Fleet API - Multi-server control for REPE.jl
# Provides unified interface for managing and communicating with multiple REPE servers

using Base.Threads: ReentrantLock

#==============================================================================#
# Types
#==============================================================================#

"""
    NodeConfig

Configuration for a remote REPE server node. The `name` defaults to `host` for simplicity.

# Example
```julia
# Simple - name defaults to hostname
NodeConfig("compute-1.local", 8080)

# With tags
NodeConfig("compute-1.local", 8080; tags=["compute", "gpu"])

# Custom name (useful for IP addresses or multiple servers on same host)
NodeConfig("192.168.1.10", 8080; name="compute-1")
```
"""
struct NodeConfig
    name::String
    host::String
    port::Int
    tags::Vector{String}
    timeout::Float64

    function NodeConfig(host::String, port::Int;
                        name::String = host,
                        tags::Vector{String} = String[],
                        timeout::Float64 = 30.0)
        (port < 1 || port > 65535) && throw(ArgumentError("port must be between 1 and 65535"))
        timeout <= 0 && throw(ArgumentError("timeout must be positive"))
        new(name, host, port, tags, timeout)
    end
end

"""
    Node

Internal representation of a connected server. Created automatically from `NodeConfig`.
"""
mutable struct Node
    name::String
    host::String
    port::Int
    tags::Set{String}
    timeout::Float64
    client::Client

    function Node(config::NodeConfig)
        client = Client(config.host, config.port; timeout=config.timeout)
        new(config.name, config.host, config.port, Set(config.tags), config.timeout, client)
    end
end

"""
    RemoteResult{T}

Structured response from remote calls.

# Fields
- `node::String` - Node that processed the request
- `value::Union{T, Nothing}` - Result value (nothing on failure)
- `error::Union{Exception, Nothing}` - Exception (nothing on success)
- `elapsed::Float64` - Time taken in seconds
"""
struct RemoteResult{T}
    node::String
    value::Union{T, Nothing}
    error::Union{Exception, Nothing}
    elapsed::Float64
end

"""
    succeeded(r::RemoteResult) -> Bool

Check if the remote call succeeded (no error).
"""
succeeded(r::RemoteResult) = r.error === nothing

"""
    failed(r::RemoteResult) -> Bool

Check if the remote call failed (has error).
"""
failed(r::RemoteResult) = r.error !== nothing

"""
    Base.getindex(r::RemoteResult)

Get the value from a RemoteResult, or throw the error if it failed.
"""
function Base.getindex(r::RemoteResult)
    r.error !== nothing && throw(r.error)
    return r.value
end

"""
    HealthStatus

Result of a health check for a single node.
"""
const HealthStatus = NamedTuple{(:healthy, :latency, :error), Tuple{Bool, Float64, Union{Exception, Nothing}}}

"""
    Fleet

The main interface for managing multiple REPE server nodes.

# Example
```julia
config = [
    NodeConfig("compute-1.local", 8080; tags=["compute"]),
    NodeConfig("compute-2.local", 8080; tags=["compute"]),
    NodeConfig("storage.local", 8080; tags=["storage"]),
]

fleet = Fleet(config)
connect!(fleet)

# Broadcast to all nodes
results = broadcast(fleet, "/status")

# Filter by tag
results = broadcast(fleet, "/compute", Dict("value" => 42); tags=["compute"])

disconnect!(fleet)
```
"""
mutable struct Fleet
    nodes::Dict{String, Node}
    nodes_lock::ReentrantLock
    default_timeout::Float64
    retry_policy::NamedTuple{(:max_attempts, :delay), Tuple{Int, Float64}}

    function Fleet(configs::Vector{NodeConfig};
                   timeout::Float64 = 30.0,
                   max_retry_attempts::Int = 3,
                   retry_delay::Float64 = 1.0)
        timeout <= 0 && throw(ArgumentError("timeout must be positive"))
        max_retry_attempts < 1 && throw(ArgumentError("max_retry_attempts must be at least 1"))
        retry_delay < 0 && throw(ArgumentError("retry_delay must be non-negative"))

        # Check for duplicate names BEFORE creating any nodes
        # (to provide clear error messages before network errors)
        seen_names = Set{String}()
        for config in configs
            if config.name in seen_names
                throw(ArgumentError("Duplicate node name: \"$(config.name)\". Multiple servers on the same host require explicit unique names."))
            end
            push!(seen_names, config.name)
        end

        # Now create nodes
        nodes = Dict{String, Node}()
        for config in configs
            nodes[config.name] = Node(config)
        end

        new(nodes, ReentrantLock(), timeout, (max_attempts=max_retry_attempts, delay=retry_delay))
    end

    function Fleet(nodes_vec::Vector{Node};
                   timeout::Float64 = 30.0,
                   max_retry_attempts::Int = 3,
                   retry_delay::Float64 = 1.0)
        timeout <= 0 && throw(ArgumentError("timeout must be positive"))
        max_retry_attempts < 1 && throw(ArgumentError("max_retry_attempts must be at least 1"))
        retry_delay < 0 && throw(ArgumentError("retry_delay must be non-negative"))

        # Check for duplicate names first
        seen_names = Set{String}()
        for node in nodes_vec
            if node.name in seen_names
                throw(ArgumentError("Duplicate node name: \"$(node.name)\". Multiple servers on the same host require explicit unique names."))
            end
            push!(seen_names, node.name)
        end

        # Add nodes to dict
        nodes = Dict{String, Node}()
        for node in nodes_vec
            nodes[node.name] = node
        end

        new(nodes, ReentrantLock(), timeout, (max_attempts=max_retry_attempts, delay=retry_delay))
    end
end

# Empty fleet constructor
Fleet() = Fleet(NodeConfig[])

#==============================================================================#
# Connection Management
#==============================================================================#

"""
    connect!(fleet::Fleet) -> (connected=Vector{String}, failed=Vector{String})

Connect to all nodes in the fleet. Returns a named tuple with lists of
successfully connected and failed node names.
"""
function connect!(fleet::Fleet)
    node_list = lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end

    connected = String[]
    failed = String[]

    # Connect in parallel using tasks
    tasks = Dict{String, Task}()
    for node in node_list
        tasks[node.name] = @async begin
            try
                if !isconnected(node.client)
                    connect(node.client)
                end
                return true
            catch e
                return e
            end
        end
    end

    # Collect results
    for (name, task) in tasks
        result = fetch(task)
        if result === true
            push!(connected, name)
        else
            push!(failed, name)
        end
    end

    return (connected=connected, failed=failed)
end

"""
    disconnect!(fleet::Fleet) -> (disconnected=Vector{String}, failed=Vector{String})

Disconnect from all nodes in the fleet. Returns a named tuple with lists of
successfully disconnected and failed node names.
"""
function disconnect!(fleet::Fleet)
    node_list = lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end

    disconnected = String[]
    failed = String[]

    for node in node_list
        try
            if isconnected(node.client)
                disconnect(node.client)
            end
            push!(disconnected, node.name)
        catch e
            push!(failed, node.name)
        end
    end

    return (disconnected=disconnected, failed=failed)
end

"""
    reconnect!(fleet::Fleet) -> (reconnected=Vector{String}, failed=Vector{String})

Reconnect disconnected nodes. Returns a named tuple with lists of
successfully reconnected and failed node names.
"""
function reconnect!(fleet::Fleet)
    node_list = lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end

    reconnected = String[]
    failed = String[]

    # Reconnect in parallel
    tasks = Dict{String, Task}()
    for node in node_list
        if !isconnected(node.client)
            tasks[node.name] = @async begin
                try
                    # Disconnect first to clean up any stale state
                    try
                        disconnect(node.client)
                    catch
                    end
                    connect(node.client)
                    return true
                catch e
                    return e
                end
            end
        end
    end

    # Collect results
    for (name, task) in tasks
        result = fetch(task)
        if result === true
            push!(reconnected, name)
        else
            push!(failed, name)
        end
    end

    return (reconnected=reconnected, failed=failed)
end

"""
    isconnected(fleet::Fleet) -> Bool

Check if all nodes in the fleet are connected.
"""
function isconnected(fleet::Fleet)
    lock(fleet.nodes_lock) do
        for node in values(fleet.nodes)
            if !isconnected(node.client)
                return false
            end
        end
        return true
    end
end

"""
    isconnected(fleet::Fleet, name::String) -> Bool

Check if a specific node is connected.
"""
function isconnected(fleet::Fleet, name::String)
    lock(fleet.nodes_lock) do
        if !haskey(fleet.nodes, name)
            throw(KeyError(name))
        end
        return isconnected(fleet.nodes[name].client)
    end
end

"""
    isconnected(node::Node) -> Bool

Check if a node is connected.
"""
isconnected(node::Node) = isconnected(node.client)

#==============================================================================#
# Node Access
#==============================================================================#

"""
    nodes(fleet::Fleet) -> Vector{Node}

Get all nodes in the fleet.
"""
function nodes(fleet::Fleet)
    lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end
end

"""
    connected_nodes(fleet::Fleet) -> Vector{Node}

Get all connected nodes in the fleet.
"""
function connected_nodes(fleet::Fleet)
    lock(fleet.nodes_lock) do
        [node for node in values(fleet.nodes) if isconnected(node.client)]
    end
end

"""
    filter_nodes(fleet::Fleet; tags::Vector{String}) -> Vector{Node}

Get nodes matching all specified tags.
"""
function filter_nodes(fleet::Fleet; tags::Vector{String})
    tag_set = Set(tags)
    lock(fleet.nodes_lock) do
        [node for node in values(fleet.nodes) if tag_set ⊆ node.tags]
    end
end

"""
    Base.getindex(fleet::Fleet, name::String) -> Node

Get a node by name.
"""
function Base.getindex(fleet::Fleet, name::String)
    lock(fleet.nodes_lock) do
        if !haskey(fleet.nodes, name)
            throw(KeyError(name))
        end
        return fleet.nodes[name]
    end
end

"""
    Base.length(fleet::Fleet) -> Int

Get the number of nodes in the fleet.
"""
function Base.length(fleet::Fleet)
    lock(fleet.nodes_lock) do
        length(fleet.nodes)
    end
end

"""
    Base.keys(fleet::Fleet) -> Vector{String}

Get all node names in the fleet.
"""
function Base.keys(fleet::Fleet)
    lock(fleet.nodes_lock) do
        collect(keys(fleet.nodes))
    end
end

#==============================================================================#
# Dynamic Node Management
#==============================================================================#

"""
    add_node!(fleet::Fleet, config::NodeConfig) -> Fleet

Add a new node to the fleet. Does not automatically connect.
Throws `ArgumentError` if a node with the same name already exists.
"""
function add_node!(fleet::Fleet, config::NodeConfig)
    lock(fleet.nodes_lock) do
        if haskey(fleet.nodes, config.name)
            throw(ArgumentError("Node \"$(config.name)\" already exists in fleet"))
        end
        fleet.nodes[config.name] = Node(config)
    end
    return fleet
end

"""
    remove_node!(fleet::Fleet, name::String) -> Fleet

Remove a node from the fleet. Disconnects the node before removal.
"""
function remove_node!(fleet::Fleet, name::String)
    lock(fleet.nodes_lock) do
        if haskey(fleet.nodes, name)
            node = fleet.nodes[name]
            try
                disconnect(node.client)
            catch
                # Ignore disconnect errors during removal
            end
            delete!(fleet.nodes, name)
        end
    end
    return fleet
end

#==============================================================================#
# Remote Invocation
#==============================================================================#

"""
    call(fleet::Fleet, node_name::String, method::String, params=nothing; kwargs...) -> RemoteResult

Call a method on a specific node.

# Arguments
- `fleet`: The fleet
- `node_name`: Name of the target node
- `method`: The RPC method name
- `params`: Optional parameters

# Keyword Arguments
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)
"""
function call(fleet::Fleet, node_name::String, method::String, params=nothing;
              query_format::QueryFormat = QUERY_JSON_POINTER,
              body_format::BodyFormat = BODY_JSON)

    node = lock(fleet.nodes_lock) do
        if !haskey(fleet.nodes, node_name)
            throw(KeyError(node_name))
        end
        fleet.nodes[node_name]
    end

    _call_with_retry(fleet, node, method, params; query_format=query_format, body_format=body_format)
end

"""
Internal function to call a node with retry logic.
"""
function _call_with_retry(fleet::Fleet, node::Node, method::String, params;
                          query_format::QueryFormat = QUERY_JSON_POINTER,
                          body_format::BodyFormat = BODY_JSON)
    start_time = time()
    last_error = nothing

    for attempt in 1:fleet.retry_policy.max_attempts
        try
            # Ensure connected
            if !isconnected(node.client)
                connect(node.client)
            end

            # Determine timeout: node-specific > fleet default
            timeout = node.timeout > 0 ? node.timeout : fleet.default_timeout

            result = send_request(node.client, method, params;
                                  query_format=query_format,
                                  body_format=body_format,
                                  timeout=timeout)

            elapsed = time() - start_time
            return RemoteResult{Any}(node.name, result, nothing, elapsed)

        catch e
            last_error = e
            if attempt < fleet.retry_policy.max_attempts
                sleep(fleet.retry_policy.delay)
            end
        end
    end

    elapsed = time() - start_time
    return RemoteResult{Any}(node.name, nothing, last_error, elapsed)
end

"""
    broadcast(fleet::Fleet, method::String, params=nothing; tags=String[], kwargs...) -> Dict{String, RemoteResult}

Call a method on all matching nodes in parallel.

# Arguments
- `fleet`: The fleet
- `method`: The RPC method name
- `params`: Optional parameters (same params sent to all nodes)

# Keyword Arguments
- `tags`: Filter nodes by tags (empty means all nodes)
- `query_format`: Format for the method name (default: QUERY_JSON_POINTER)
- `body_format`: Format for serializing params (default: BODY_JSON)
"""
function broadcast(fleet::Fleet, method::String, params=nothing;
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

    # Execute in parallel
    results = Dict{String, RemoteResult}()
    tasks = Dict{String, Task}()

    for node in target_nodes
        tasks[node.name] = @async _call_with_retry(fleet, node, method, params;
                                                    query_format=query_format,
                                                    body_format=body_format)
    end

    # Collect results
    for (name, task) in tasks
        results[name] = fetch(task)
    end

    return results
end

"""
    map_reduce(reduce_fn, fleet::Fleet, method::String, params=nothing; tags=String[], kwargs...) -> Any

Broadcast a method call and reduce the results.

# Arguments
- `reduce_fn`: Function to reduce results, receives Vector{RemoteResult}
- `fleet`: The fleet
- `method`: The RPC method name
- `params`: Optional parameters

# Keyword Arguments
- `tags`: Filter nodes by tags (empty means all nodes)
- `query_format`: Format for the method name
- `body_format`: Format for serializing params

# Example
```julia
total = map_reduce(fleet, "/compute", Dict("value" => 10); tags=["compute"]) do results
    sum(r.value["result"] for r in results if succeeded(r))
end
```
"""
function map_reduce(reduce_fn::Function, fleet::Fleet, method::String, params=nothing;
                    tags::Vector{String} = String[],
                    query_format::QueryFormat = QUERY_JSON_POINTER,
                    body_format::BodyFormat = BODY_JSON)

    results_dict = broadcast(fleet, method, params;
                             tags=tags,
                             query_format=query_format,
                             body_format=body_format)

    results_vec = collect(values(results_dict))
    return reduce_fn(results_vec)
end

#==============================================================================#
# Callable Syntax
#==============================================================================#

"""
    (fleet::Fleet)(method::String, params=nothing; tags=String[], kwargs...)

Callable broadcast syntax. Equivalent to `broadcast(fleet, method, params; tags=tags, kwargs...)`.
"""
function (fleet::Fleet)(method::String, params=nothing;
                        tags::Vector{String} = String[],
                        query_format::QueryFormat = QUERY_JSON_POINTER,
                        body_format::BodyFormat = BODY_JSON)
    broadcast(fleet, method, params; tags=tags, query_format=query_format, body_format=body_format)
end

"""
    (fleet::Fleet)(node_name::String, method::String, params=nothing; kwargs...)

Callable single-node syntax. Equivalent to `call(fleet, node_name, method, params; kwargs...)`.
"""
function (fleet::Fleet)(node_name::String, method::String, params;
                        query_format::QueryFormat = QUERY_JSON_POINTER,
                        body_format::BodyFormat = BODY_JSON)
    call(fleet, node_name, method, params; query_format=query_format, body_format=body_format)
end

#==============================================================================#
# Health Monitoring
#==============================================================================#

"""
    health_check(fleet::Fleet; health_endpoint::String="/status") -> Dict{String, HealthStatus}

Check health of all nodes by calling a health endpoint.

Returns a Dict mapping node names to HealthStatus named tuples with fields:
- `healthy::Bool` - Whether the node responded successfully
- `latency::Float64` - Response time in seconds
- `error::Union{Exception, Nothing}` - Error if unhealthy
"""
function health_check(fleet::Fleet; health_endpoint::String = "/status")
    results = Dict{String, HealthStatus}()

    # Snapshot nodes
    node_list = lock(fleet.nodes_lock) do
        collect(values(fleet.nodes))
    end

    # Check in parallel
    tasks = Dict{String, Task}()
    for node in node_list
        tasks[node.name] = @async begin
            start_time = time()
            try
                if !isconnected(node.client)
                    connect(node.client)
                end
                send_request(node.client, health_endpoint, nothing; timeout=5.0)
                latency = time() - start_time
                return (healthy=true, latency=latency, error=nothing)
            catch e
                latency = time() - start_time
                return (healthy=false, latency=latency, error=e)
            end
        end
    end

    # Collect results
    for (name, task) in tasks
        results[name] = fetch(task)
    end

    return results
end

#==============================================================================#
# Pretty Printing
#==============================================================================#

function Base.show(io::IO, config::NodeConfig)
    print(io, "NodeConfig(\"$(config.host)\", $(config.port)")
    if config.name != config.host
        print(io, "; name=\"$(config.name)\"")
    end
    if !isempty(config.tags)
        print(io, ", tags=$(config.tags)")
    end
    print(io, ")")
end

function Base.show(io::IO, node::Node)
    status = isconnected(node.client) ? "connected" : "disconnected"
    print(io, "Node(\"$(node.name)\", $(node.host):$(node.port), $status)")
end

function Base.show(io::IO, fleet::Fleet)
    n = length(fleet)
    connected = length(connected_nodes(fleet))
    print(io, "Fleet($connected/$n nodes connected)")
end

function Base.show(io::IO, r::RemoteResult)
    if succeeded(r)
        print(io, "RemoteResult($(r.node), success, $(round(r.elapsed * 1000, digits=1))ms)")
    else
        print(io, "RemoteResult($(r.node), failed: $(typeof(r.error)), $(round(r.elapsed * 1000, digits=1))ms)")
    end
end
