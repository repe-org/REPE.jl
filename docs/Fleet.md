# Fleet API - Multi-Server Control

The Fleet API provides a unified interface for managing and communicating with multiple REPE servers. It supports both TCP (`Fleet`) for bidirectional communication and UDP (`UniUDPFleet`) for fire-and-forget broadcasting.

## Features

- Unified interface to treat multiple servers as a single logical unit
- Tag-based node filtering for targeted operations
- Parallel execution with structured results per node
- Automatic retry with configurable policy (TCP Fleet)
- Dynamic node management at runtime
- Thread-safe concurrent operations
- Callable syntax for intuitive invocation

## TCP Fleet (Bidirectional)

Use `Fleet` when you need request/response communication with multiple servers.

### Quick Start

```julia
using REPE

# Define fleet configuration
config = [
    NodeConfig("compute-1.local", 8080; tags=["compute"]),
    NodeConfig("compute-2.local", 8080; tags=["compute"]),
    NodeConfig("storage.local", 8080; tags=["storage"]),
]

fleet = Fleet(config)
connect!(fleet)

# Broadcast to all nodes
results = broadcast(fleet, "/status")

for (name, result) in results
    if succeeded(result)
        println("$name: $(result.value)")
    else
        println("$name: ERROR - $(result.error)")
    end
end

disconnect!(fleet)
```

### NodeConfig

Configuration for a remote server node.

```julia
# Simple - name defaults to hostname
NodeConfig("compute-1.local", 8080)

# With tags for filtering
NodeConfig("compute-1.local", 8080; tags=["compute", "gpu"])

# Custom name (required for multiple servers on same host)
NodeConfig("192.168.1.10", 8080; name="compute-1")
NodeConfig("192.168.1.10", 8081; name="compute-2")

# Custom timeout (overrides fleet default)
NodeConfig("slow-server.local", 8080; timeout=60.0)
```

| Field | Default | Description |
|-------|---------|-------------|
| `host` | required | Hostname or IP address |
| `port` | required | Port number (1-65535) |
| `name` | `host` | Unique identifier |
| `tags` | `[]` | Tags for filtering |
| `timeout` | `30.0` | Request timeout in seconds |

**Timeout precedence:** `NodeConfig.timeout` > `Fleet.default_timeout` > hardcoded default (30.0s)

### Fleet Construction

```julia
# From NodeConfig vector
fleet = Fleet(configs; timeout=30.0, max_retry_attempts=3, retry_delay=1.0)

# Empty fleet (for dynamic population)
fleet = Fleet()
```

**Note:** Duplicate node names throw `ArgumentError`:

```julia
# ERROR: duplicate name "server.local"
Fleet([
    NodeConfig("server.local", 8080),
    NodeConfig("server.local", 8081),
])

# OK: explicit unique names
Fleet([
    NodeConfig("server.local", 8080; name="service-a"),
    NodeConfig("server.local", 8081; name="service-b"),
])
```

### Connection Management

```julia
# Connect to all nodes
result = connect!(fleet)
println("Connected: $(result.connected)")
println("Failed: $(result.failed)")

# Disconnect from all nodes
result = disconnect!(fleet)

# Reconnect dropped connections
result = reconnect!(fleet)

# Check connection status
isconnected(fleet)              # All nodes connected?
isconnected(fleet, "node-1")    # Specific node?
```

### Node Access

```julia
# Get all nodes
all_nodes = nodes(fleet)

# Get only connected nodes
active = connected_nodes(fleet)

# Filter by tags (returns nodes matching ALL specified tags)
compute_nodes = filter_nodes(fleet; tags=["compute"])
gpu_nodes = filter_nodes(fleet; tags=["compute", "gpu"])

# Access by name
node = fleet["compute-1.local"]

# Get all node names
names = keys(fleet)

# Get node count
n = length(fleet)
```

### Remote Invocation

```julia
# Call a specific node
result = call(fleet, "compute-1.local", "/compute", Dict("value" => 42))
if succeeded(result)
    println("Result: $(result.value)")
end

# Broadcast to all nodes
results = broadcast(fleet, "/status")

# Broadcast with tag filtering
results = broadcast(fleet, "/compute", Dict("x" => 10); tags=["compute"])

# Callable syntax - broadcast
results = fleet("/status")
results = fleet("/compute", Dict("x" => 10); tags=["compute"])

# Callable syntax - single node
result = fleet("compute-1.local", "/compute", Dict("x" => 10))
```

### Map-Reduce

Aggregate results from multiple nodes:

```julia
# Sum results from compute nodes
total = map_reduce(fleet, "/compute", Dict("value" => 10); tags=["compute"]) do results
    sum(r.value["result"] for r in results if succeeded(r))
end

# Count successful responses
count = map_reduce(fleet, "/ping") do results
    count(succeeded, results)
end

# Collect all values
all_values = map_reduce(fleet, "/data") do results
    [r.value for r in results if succeeded(r)]
end
```

### RemoteResult

Structured response from remote calls:

```julia
struct RemoteResult{T}
    node::String                       # Node that processed the request
    value::Union{T, Nothing}           # Result value (nothing on failure)
    error::Union{Exception, Nothing}   # Exception (nothing on success)
    elapsed::Float64                   # Time taken in seconds
end

# Check success/failure
succeeded(result)  # true if error === nothing
failed(result)     # true if error !== nothing

# Get value (throws if failed)
value = result[]
```

### Health Monitoring

```julia
health = health_check(fleet; health_endpoint="/status")

for (name, status) in health
    if status.healthy
        println("$name: $(round(status.latency * 1000, digits=1))ms")
    else
        println("$name: UNHEALTHY - $(status.error)")
    end
end
```

`HealthStatus` is a NamedTuple with fields:
- `healthy::Bool` - Whether the node responded successfully
- `latency::Float64` - Response time in seconds
- `error::Union{Exception, Nothing}` - Error if unhealthy

### Dynamic Node Management

```julia
# Add a node at runtime
add_node!(fleet, NodeConfig("compute-4.local", 8080; tags=["compute"]))
connect!(fleet)  # Connect newly added nodes

# Remove a node (disconnects automatically)
remove_node!(fleet, "compute-4.local")
```

### Complete Example

```julia
using REPE

const FLEET_CONFIG = [
    NodeConfig("compute-1.local", 8080; tags=["compute"]),
    NodeConfig("compute-2.local", 8080; tags=["compute"]),
    NodeConfig("compute-3.local", 8080; tags=["compute"]),
    NodeConfig("storage.local", 8080; tags=["storage"]),
]

function main()
    fleet = Fleet(FLEET_CONFIG; timeout=30.0, max_retry_attempts=3)

    try
        # Connect
        status = connect!(fleet)
        println("Connected: $(length(status.connected))/$(length(fleet)) nodes")

        # Health check
        println("\n--- Fleet Health ---")
        for (name, h) in health_check(fleet)
            symbol = h.healthy ? "+" : "-"
            msg = h.healthy ? "$(round(h.latency * 1000, digits=1))ms" : h.error
            println("[$symbol] $name: $msg")
        end

        # Broadcast to compute nodes
        println("\n--- Compute Results ---")
        results = broadcast(fleet, "/compute", Dict("value" => 42); tags=["compute"])
        for (name, r) in results
            succeeded(r) && println("$name: $(r.value)")
        end

        # Aggregate
        total = map_reduce(fleet, "/compute", Dict("value" => 50); tags=["compute"]) do results
            sum(r.value["result"] for r in results if succeeded(r))
        end
        println("\nTotal: $total")

    finally
        disconnect!(fleet)
    end
end

main()
```

---

## UniUDP Fleet (Unidirectional)

Use `UniUDPFleet` for fire-and-forget broadcasting over UDP. This is ideal for:

- One-way satellite or radio links
- Sensor networks with asymmetric connectivity
- Broadcast/multicast scenarios
- High-throughput logging without acknowledgments

### Quick Start

```julia
using REPE

# Define UniUDP fleet
config = [
    UniUDPNodeConfig("gateway-1.local", 5000; tags=["primary"]),
    UniUDPNodeConfig("gateway-2.local", 5000; tags=["backup"]),
    UniUDPNodeConfig("logger.local", 5001; tags=["logging"]),
]

fleet = UniUDPFleet(config)

# Broadcast notification to all
results = send_notify(fleet, "/sensor/reading", Dict("value" => 23.5))

for (name, result) in results
    if succeeded(result)
        println("$name: sent (msg_id=$(result.message_id))")
    else
        println("$name: FAILED - $(result.error)")
    end
end

close(fleet)
```

### UniUDPNodeConfig

Configuration for a UniUDP target endpoint:

```julia
# Simple configuration
UniUDPNodeConfig("sensor-gateway.local", 5000)

# With reliability settings for lossy links
UniUDPNodeConfig("satellite-uplink.local", 5000;
    redundancy = 3,        # Triple redundancy
    fec_group_size = 4,    # XOR parity every 4 chunks
    tags = ["uplink", "critical"]
)

# Multiple receivers on same host
UniUDPNodeConfig("collector.local", 5000; name="collector-primary")
UniUDPNodeConfig("collector.local", 5001; name="collector-backup")
```

| Field | Default | Description |
|-------|---------|-------------|
| `host` | required | Hostname or IP address |
| `port` | required | Port number (1-65535) |
| `name` | `host` | Unique identifier |
| `tags` | `[]` | Tags for filtering |
| `redundancy` | `1` | Packet redundancy (1-N) |
| `chunk_size` | `1024` | Bytes per chunk |
| `fec_group_size` | `4` | FEC parity group size |

### Send Operations

```julia
# Broadcast notification to all nodes
results = send_notify(fleet, "/sensor/reading", Dict("value" => 23.5))

# Broadcast with tag filtering
results = send_notify(fleet, "/alert", Dict("level" => "warning"); tags=["primary"])

# Broadcast request (fire-and-forget, server handles result via callback)
results = send_request(fleet, "/compute/analyze", Dict("data_id" => "42"))

# Notify all nodes (convenience function, no tag filtering)
results = notify_all(fleet, "/heartbeat", Dict("source" => "controller"))

# Callable syntax - broadcast
results = fleet("/sensor/reading", Dict("value" => 23.5))
results = fleet("/alert", Dict("level" => "warning"); tags=["primary"])

# Callable syntax - single node
result = fleet("gateway-1.local", "/sensor/reading", Dict("value" => 23.5))
```

### SendResult

Result from a UniUDP send operation:

```julia
struct SendResult
    node::String                       # Target node name
    message_id::UInt64                 # UniUDP message ID
    error::Union{Exception, Nothing}   # Exception (nothing on success)
    elapsed::Float64                   # Time taken in seconds
end

# Check success/failure
succeeded(result)  # true if error === nothing
failed(result)     # true if error !== nothing
```

**Note:** `succeeded(result)` indicates the send syscall completed, not delivery confirmation. UDP is inherently unreliable.

### Node Management

```julia
# Get all nodes
all_nodes = nodes(fleet)

# Filter by tags
sensor_nodes = filter_nodes(fleet; tags=["sensor"])

# Access by name
node = fleet["gateway-1.local"]

# Add/remove nodes dynamically
add_node!(fleet, UniUDPNodeConfig("gateway-3.local", 5000))
remove_node!(fleet, "gateway-1.local")

# Close all sockets
close(fleet)
```

### High-Reliability Configuration

For critical notifications over lossy links:

```julia
critical_fleet = UniUDPFleet([
    UniUDPNodeConfig("control-1.local", 5000;
        name = "control-primary",
        redundancy = 3,         # Triple redundancy
        fec_group_size = 4,     # FEC for additional recovery
        tags = ["control", "critical"]
    ),
    UniUDPNodeConfig("control-2.local", 5000;
        name = "control-backup",
        redundancy = 3,
        fec_group_size = 4,
        tags = ["control", "critical"]
    ),
])

# Emergency broadcast with high reliability
send_notify(critical_fleet, "/emergency/shutdown", Dict(
    "reason" => "overheat",
    "timestamp" => time()
))
```

### Mixed Fleet Pattern

Combine TCP and UniUDP fleets for hybrid architectures:

```julia
# TCP fleet for request/response
tcp_fleet = Fleet([
    NodeConfig("api-server-1.local", 8080; tags=["api"]),
    NodeConfig("api-server-2.local", 8080; tags=["api"]),
])
connect!(tcp_fleet)

# UniUDP fleet for fire-and-forget notifications
udp_fleet = UniUDPFleet([
    UniUDPNodeConfig("monitor-1.local", 5000; tags=["monitor"]),
    UniUDPNodeConfig("monitor-2.local", 5000; tags=["monitor"]),
])

# Coordinator: get response via TCP, notify monitors via UDP
function process_request(data)
    results = broadcast(tcp_fleet, "/process", data; tags=["api"])

    send_notify(udp_fleet, "/activity", Dict(
        "request" => data,
        "processed_by" => [r.node for r in values(results) if succeeded(r)]
    ))

    return results
end
```

---

## API Reference

### TCP Fleet Types

| Type | Description |
|------|-------------|
| `NodeConfig` | Configuration for a TCP server node |
| `Node` | Internal representation of a connected server |
| `Fleet` | Multi-server control interface |
| `RemoteResult{T}` | Structured response from remote calls |
| `HealthStatus` | Health check result (NamedTuple) |

### TCP Fleet Functions

| Function | Description |
|----------|-------------|
| `Fleet(configs; timeout, max_retry_attempts, retry_delay)` | Create fleet |
| `connect!(fleet)` | Connect to all nodes |
| `disconnect!(fleet)` | Disconnect from all nodes |
| `reconnect!(fleet)` | Reconnect dropped connections |
| `isconnected(fleet)` / `isconnected(fleet, name)` | Check connection status |
| `nodes(fleet)` | Get all nodes |
| `connected_nodes(fleet)` | Get connected nodes |
| `filter_nodes(fleet; tags)` | Filter nodes by tags |
| `add_node!(fleet, config)` | Add node at runtime |
| `remove_node!(fleet, name)` | Remove and disconnect node |
| `call(fleet, node_name, method, params)` | Call specific node |
| `broadcast(fleet, method, params; tags)` | Call all matching nodes |
| `map_reduce(fn, fleet, method, params; tags)` | Broadcast and reduce |
| `health_check(fleet; health_endpoint)` | Check node health |

### UniUDP Fleet Types

| Type | Description |
|------|-------------|
| `UniUDPNodeConfig` | Configuration for a UniUDP endpoint |
| `UniUDPNode` | Internal representation of a UniUDP target |
| `UniUDPFleet` | Multi-endpoint broadcast interface |
| `SendResult` | Result from send operation |

### UniUDP Fleet Functions

| Function | Description |
|----------|-------------|
| `UniUDPFleet(configs)` | Create fleet |
| `nodes(fleet)` | Get all nodes |
| `filter_nodes(fleet; tags)` | Filter nodes by tags |
| `add_node!(fleet, config)` | Add node at runtime |
| `remove_node!(fleet, name)` | Remove node |
| `close(fleet)` | Close all sockets |
| `send_notify(fleet, method, params; tags)` | Broadcast notification |
| `send_request(fleet, method, params; tags)` | Broadcast request |
| `notify_all(fleet, method, params)` | Notify all nodes |

### Convenience Functions

| Function | Description |
|----------|-------------|
| `succeeded(result)` | Check if result succeeded |
| `failed(result)` | Check if result failed |

---

## Implementation Notes

### Thread Safety

Both `Fleet` and `UniUDPFleet` use `ReentrantLock` to protect their internal node dictionaries:

- **Read operations** (`nodes`, `filter_nodes`, `broadcast`): Acquire lock briefly to snapshot nodes, then release before executing requests
- **Write operations** (`add_node!`, `remove_node!`): Acquire lock, modify dict, release lock
- **Requests in flight** operate on snapshots; concurrent modifications won't affect them

### Error Handling

**TCP Fleet:**
- Connection failures are captured and returned, not thrown
- Request failures are captured in `RemoteResult.error`
- Retry is automatic based on fleet's `retry_policy`

**UniUDP Fleet:**
- Send errors are captured in `SendResult.error`
- `succeeded()` indicates send syscall completed, not delivery
- For delivery confirmation, use application-level acknowledgments

### Key Differences: TCP vs UniUDP Fleet

| Aspect | TCP Fleet | UniUDP Fleet |
|--------|-----------|--------------|
| Communication | Bidirectional | Unidirectional |
| Connection state | Persistent TCP | Stateless UDP |
| `call()` | Returns response | N/A |
| `broadcast()` | Collects responses | Fire-and-forget |
| `map_reduce()` | Aggregates results | N/A |
| `connect!()` | Establishes connections | N/A |
| Error indication | Response delivery | Send syscall only |
