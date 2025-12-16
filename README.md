# REPE.jl

Julia implementation of the [REPE (Remote Efficient Protocol Extension)](https://github.com/repe-org/REPE) RPC specification. REPE is a fast and simple binary RPC protocol that supports flexible data formats and query specifications.

## Features

- Full implementation of the official [REPE v1 specification](https://github.com/repe-org/REPE)
- Binary protocol with little-endian encoding
- Support for multiple data formats (JSON, BEVE, UTF-8, raw binary)
- Asynchronous client/server architecture
- Error handling with standardized error codes
- Notification support (fire-and-forget messages)
- **Registry support** for serving dictionaries with JSON Pointer syntax (Glaze-compatible)
- **UniUDP support** for REPE over unidirectional UDP with redundancy and FEC
- **Fleet API** for multi-server control with TCP and UniUDP support
- Compatible with C++ Glaze implementation
- Comprehensive test suite with 650+ unit tests
- Integration tested with Glaze C++ servers

## Requirements

- Julia 1.6 or higher
- For C++ server (optional):
  - C++20 compatible compiler
  - CMake 3.15+
  - Glaze library (automatically fetched by CMake)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/stephenberry/REPE.jl")
```

## Quick Start

### Server Example

```julia
using REPE

# Create server
server = Server("localhost", 8080)

# Enable stack traces for easier debugging (optional)
# server = Server("localhost", 8080; print_stacktrace=true)

# Register handlers
REPE.register(server, "/api/add", function(params, request)
    return Dict("result" => params["a"] + params["b"])
end)

# Start server (blocking)
listen(server)

# Or start server asynchronously
listen(server; async=true)

# Stop the server when done
stop(server)
```

Pass `print_stacktrace=true` when constructing the server if you want REPE to log stack traces alongside the standard error messages while you are debugging.

### Client Example

```julia
using REPE

# Create and connect client
client = Client("localhost", 8080)
connect(client)

# Make RPC call
result = send_request(client, "/api/add", Dict("a" => 10, "b" => 20))
println(result["result"])  # 30

# Send notification (no response expected)
send_notify(client, "/api/log", "Event occurred")

disconnect(client)
```

### Typed Responses

REPE can decode JSON or BEVE responses directly into Julia structs. Define standard Julia structs for your payloads and pass the type (or a `result_type` keyword) when calling `send_request` or `send_request_async`.

```julia
using REPE

struct SensorReading
    id::Int
    status::String
end

client = Client("localhost", 8080)
connect(client)

# JSON response decoded straight into SensorReading
reading = send_request(SensorReading, client, "/api/sensor", Dict("id" => 42))
@assert reading isa SensorReading

# Keyword form is also available
reading2 = send_request(client, "/api/sensor", Dict("id" => 42);
                        result_type = SensorReading)

# Async variant
task = send_request_async(SensorReading, client, "/api/sensor", Dict("id" => 42))
reading3 = fetch(task)

# BEVE responses are supported automatically by the typed API
reading_beve = send_request(SensorReading, client, "/api/sensor/beve", Dict())

disconnect(client)
```

## Protocol Specification

For the complete protocol specification, see the [official REPE documentation](https://github.com/repe-org/REPE).

REPE messages consist of a fixed 48-byte header followed by optional query and body sections:

```
[Header (48 bytes)] [Query (variable)] [Body (variable)]
```

### Header Structure

- `length` (8 bytes): Total message length
- `spec` (2 bytes): Magic number (0x1507)
- `version` (1 byte): Protocol version (1)
- `notify` (1 byte): No-response flag
- `reserved` (4 bytes): Must be zero
- `id` (8 bytes): Request identifier
- `query_length` (8 bytes): Query section length
- `body_length` (8 bytes): Body section length
- `query_format` (2 bytes): Query format type
- `body_format` (2 bytes): Body format type
- `ec` (4 bytes): Error code

## Data Formats

### Query Formats
- `QUERY_RAW_BINARY` (0): Raw binary data
- `QUERY_JSON_POINTER` (1): JSON Pointer syntax

### Body Formats
- `REPE.RAW_BINARY` (0): Raw binary data
- `REPE.BEVE` (1): BEVE binary format  
- `REPE.JSON` (2): JSON data
- `REPE.UTF8` (3): UTF-8 text

Note: The underlying protocol constants are `BODY_RAW_BINARY`, `BODY_BEVE`, `BODY_JSON`, and `BODY_UTF8`, but the convenient aliases above are recommended for use in your code.

## Error Codes

Standard REPE error codes (0-4095 reserved):
- `EC_OK` (0): No error
- `EC_VERSION_MISMATCH` (1): Protocol version mismatch
- `EC_INVALID_HEADER` (2): Invalid header
- `EC_INVALID_QUERY` (3): Invalid query
- `EC_INVALID_BODY` (4): Invalid body
- `EC_PARSE_ERROR` (5): Parse error
- `EC_METHOD_NOT_FOUND` (6): Method not found
- `EC_TIMEOUT` (7): Request timeout

Application-specific error codes start at 4096.

## Advanced Usage

### Custom Middleware

```julia
server = Server("localhost", 8080)

# Add logging middleware
REPE.use(server, function(request)
    println("Request: ", parse_query(request))
    return nothing  # Continue processing
end)

# Add authentication middleware
REPE.use(server, function(request)
    if !check_auth(request)  # check_auth is your custom function
        # Return custom application error (codes >= 4096)
        return ErrorCode(4096)  # Custom EC_UNAUTHORIZED
    end
    return nothing
end)
```

### Different Data Formats

```julia
# Send JSON data
result = send_request(client, "/api/data", 
                     Dict("key" => "value"),
                     body_format = REPE.JSON)

# Send BEVE binary data (compact and efficient)
result = send_request(client, "/api/data",
                     Dict("numbers" => [1, 2, 3], "flag" => true),
                     body_format = REPE.BEVE)

# Send plain text
result = send_request(client, "/api/text",
                     "Hello, World!",
                     body_format = REPE.UTF8)

# Send raw binary
data = UInt8[1, 2, 3, 4, 5]
result = send_request(client, "/api/binary",
                     data,
                     body_format = REPE.RAW_BINARY)
```

### Timeout Control

```julia
# Set default timeout for client
client = Client("localhost", 8080; timeout=10.0)

# Override timeout for specific request
result = send_request(client, "/api/slow", params, timeout=60.0)
```

### Async and Batch Operations

```julia
# Async request - returns a Task
task = send_request_async(client, "/api/data", params,
                         body_format = REPE.JSON)
result = fetch(task)

# Batch multiple requests
requests = [
    ("/api/method1", Dict("param" => 1)),
    ("/api/method2", Dict("param" => 2)),
    ("/api/method3", Dict("param" => 3))
]
tasks = batch(client, requests; body_format = REPE.JSON)
results = await_batch(tasks)

# Check connection status
if isconnected(client)
    println("Client is connected")
end
```

## Registry

The `Registry` provides a convenient way to serve variables and functions using JSON Pointer syntax, matching the behavior of the Glaze C++ REPE registry. This allows you to expose a dictionary-like structure where:

- **Empty body** = READ the value at the path
- **Non-empty body + Function** = CALL the function with the body as arguments
- **Non-empty body + non-Function** = WRITE the value to the path

### Basic Registry Usage

```julia
using REPE

# Create a registry with variables and functions
registry = Registry(
    "counter" => 0,
    "config" => Dict("timeout" => 30, "retries" => 3),
    "add" => (;a, b) -> a + b,           # kwargs-style function
    "multiply" => (x, y) -> x * y         # positional args (use array body)
)

# Serve the registry
server = Server("localhost", 8080)
serve(server, registry)
listen(server)
```

### Client Access

```julia
client = Client("localhost", 8080)
connect(client)

# READ a value (empty body)
counter = send_request(client, "/counter", nothing)  # Returns: 0

# READ nested value
timeout = send_request(client, "/config/timeout", nothing)  # Returns: 30

# WRITE a value (non-empty body to non-function)
send_request(client, "/counter", 42)  # Sets counter to 42

# CALL a function with kwargs (dict body)
result = send_request(client, "/add", Dict("a" => 10, "b" => 20))  # Returns: 30

# CALL a function with positional args (array body)
result = send_request(client, "/multiply", [4, 7])  # Returns: 28

disconnect(client)
```

### Building a Registry

```julia
# Create empty and add entries
registry = Registry()
registry["version"] = "1.0.0"
registry["debug"] = false

# Register at a path (creates nested structure)
register!(registry, "api/users/count", 0)

# Merge a dictionary at root
merge!(registry, Dict(
    "status" => "online",
    "uptime" => () -> time()
))

# Merge a dictionary at a specific path
merge!(registry, "/api/v2", Dict(
    "users" => Dict(
        "list" => () -> get_all_users(),
        "create" => (;name, email) -> create_user(name, email)
    ),
    "posts" => Dict(
        "list" => () -> get_all_posts(),
        "create" => (;title, body) -> create_post(title, body)
    )
))
# Now accessible as /api/v2/users/list, /api/v2/posts/create, etc.
```

### JSON Pointer Support

The registry uses [JSON Pointer (RFC 6901)](https://datatracker.ietf.org/doc/html/rfc6901) syntax for paths:

```julia
data = Dict(
    "users" => [
        Dict("name" => "Alice", "age" => 30),
        Dict("name" => "Bob", "age" => 25)
    ],
    "config" => Dict("timeout" => 30)
)
registry = Registry(data)

# Access nested values
resolve_json_pointer(registry, "/users/0/name")      # "Alice" (0-based array index)
resolve_json_pointer(registry, "/config/timeout")    # 30

# Set values
set_json_pointer!(registry, "/config/timeout", 60)
```

### Function Invocation

Functions in the registry are called based on how the body is structured:

| Body Type | Invocation Style | Example |
|-----------|------------------|---------|
| `Dict` | Keyword arguments | `(;a, b) -> a + b` called with `{"a": 5, "b": 3}` |
| `Array` | Positional arguments | `(x, y) -> x * y` called with `[4, 7]` |
| Empty `Dict`/`nothing` | No arguments | `() -> get_status()` |

```julia
registry = Registry(
    # Keyword args function
    "greet" => (;name, greeting="Hello") -> "$greeting, $name!",

    # Positional args function
    "sum" => (args...) -> sum(args),

    # No-arg function
    "timestamp" => () -> time()
)
```

### Path Prefix

Use `path_prefix` in `serve()` to strip a prefix from incoming requests:

```julia
registry = Registry("users" => [...], "posts" => [...])
server = Server("localhost", 8080)
serve(server, registry; path_prefix="/api/v1")
listen(server)

# Client requests /api/v1/users -> resolves to /users in registry
```

## Glaze C++ Interoperability

REPE.jl is fully compatible with the C++ Glaze implementation. You can build and run a C++ REPE server using Glaze:

### Building the C++ Server

```bash
cd cpp_server
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

### Running Integration Tests

```bash
# Start the C++ server
./cpp_server/build/repe_server 8081

# In another terminal, run Julia client
julia --project=. examples/glaze_interop.jl client localhost 8081
```

### Example C++ Server with Glaze

The repository includes a complete C++ REPE server implementation using Glaze's native REPE support (`glaze/rpc/repe/repe.hpp`). The server demonstrates:
- Binary REPE protocol handling
- JSON message parsing with Glaze
- Error handling and exception mapping
- Multiple RPC methods (add, multiply, divide, echo, status)

```julia
# Connect to Glaze C++ server
client = Client("localhost", 8081)
connect(client)

# Call C++ methods from Julia
result = send_request(client, "/add",
                     Dict("a" => 10.0, "b" => 20.0),
                     body_format = REPE.JSON)
println(result["result"])  # 30.0

# The C++ divide function properly throws exceptions for errors
try
    send_request(client, "/divide",
                Dict("numerator" => 1.0, "denominator" => 0.0),
                body_format = REPE.JSON)
catch e
    println("Caught division by zero error")
end
```

See `examples/glaze_interop.jl` and `test/run_glaze_test.sh` for complete examples.

## BEVE Binary Format Support

REPE.jl includes support for [BEVE (Bit Efficient Versatile Encoding)](https://github.com/beve-org/BEVE.jl), a compact binary serialization format that can be more efficient than JSON for certain types of data.

### When to Use BEVE

BEVE is typically better for:
- Structured data with numeric values
- Arrays and matrices  
- High-frequency message passing
- Applications requiring compact binary encoding
- Interoperability with C++ BEVE libraries

JSON remains better for:
- Human-readable debugging
- Web API compatibility
- Simple text-heavy data
- Schema-less data structures

### BEVE Usage Example

```julia
using REPE

# Complex structured data
sensor_data = Dict(
    "timestamp" => 1641038400,
    "readings" => [
        Dict("sensor_id" => "temp_01", "value" => 23.5),
        Dict("sensor_id" => "humidity_01", "value" => 45.2),
        Dict("sensor_id" => "pressure_01", "value" => 1013.25)
    ],
    "metadata" => Dict(
        "location" => Dict("lat" => 37.7749, "lon" => -122.4194),
        "device_id" => "weather_station_001"
    )
)

# Send with BEVE encoding
client = Client("localhost", 8080)
connect(client)

result = send_request(client, "/sensors/upload",
                     sensor_data,
                     body_format = REPE.BEVE)

disconnect(client)
```

### Format Comparison

You can test the efficiency of different formats:

```julia
data = Dict("matrix" => [[1,2,3], [4,5,6]], "numbers" => collect(1:100))

# Compare sizes
beve_size = length(encode_body(data, REPE.BEVE))
json_size = length(encode_body(data, REPE.JSON))

println("BEVE: $beve_size bytes")
println("JSON: $json_size bytes")
```

See `examples/beve_demo.jl` for comprehensive BEVE examples and performance comparisons.

## UniUDP - Unidirectional UDP Support

REPE.jl includes built-in support for sending REPE messages over unidirectional UDP links with configurable redundancy and forward error correction (FEC). This is useful for:

- One-way satellite or radio links
- Sensor networks with asymmetric connectivity
- Broadcast/multicast scenarios
- High-throughput logging where acknowledgments aren't needed

### UniUDP Client

```julia
using REPE

client = UniUDPClient(ip"192.168.1.100", 5000;
    redundancy = 2,       # Send each chunk twice
    chunk_size = 1024,    # Bytes per chunk
    fec_group_size = 4    # XOR parity every 4 chunks
)

# Fire-and-forget notification
send_notify(client, "/sensor/temperature", Dict("value" => 23.5))

close(client)
```

### UniUDP Server

```julia
using REPE

server = UniUDPServer(5000;
    response_callback = (method, result, msg) -> println("Result: $result")
)

register(server, "/compute/square") do params, msg
    return params["x"]^2
end

listen(server)
```

For complete documentation including the packet format, FEC configuration, and raw protocol access, see [docs/UniUDP.md](docs/UniUDP.md).

## Fleet API - Multi-Server Control

REPE.jl includes a Fleet API for managing and communicating with multiple servers through a unified interface. This supports both TCP (`Fleet`) for bidirectional communication and UDP (`UniUDPFleet`) for fire-and-forget broadcasting.

### TCP Fleet

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

# Broadcast to all compute nodes
results = broadcast(fleet, "/compute", Dict("value" => 42); tags=["compute"])

for (name, result) in results
    if succeeded(result)
        println("$name: $(result.value)")
    end
end

# Aggregate results with map_reduce
total = map_reduce(fleet, "/compute", Dict("value" => 10); tags=["compute"]) do results
    sum(r.value["result"] for r in results if succeeded(r))
end

disconnect!(fleet)
```

### UniUDP Fleet

```julia
using REPE

# Define UniUDP fleet for sensor network
config = [
    UniUDPNodeConfig("gateway-1.local", 5000; tags=["primary"]),
    UniUDPNodeConfig("gateway-2.local", 5000; tags=["backup"]),
]

fleet = UniUDPFleet(config)

# Fire-and-forget broadcast to all nodes
results = send_notify(fleet, "/sensor/reading", Dict("value" => 23.5))

# Filter by tag
results = send_notify(fleet, "/alert", Dict("level" => "warning"); tags=["primary"])

close(fleet)
```

For complete documentation including tag-based filtering, health monitoring, dynamic node management, and mixed fleet patterns, see [docs/Fleet.md](docs/Fleet.md).

## Testing

### Run Julia Unit Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

All 650+ unit tests should pass, covering:
- Header serialization/deserialization
- Message encoding/decoding (JSON, UTF8, BEVE, binary)
- Client-server communication
- Concurrent/async operations
- Error handling
- BEVE binary format support
- Registry with JSON Pointer resolution
- UniUDP protocol (chunking, redundancy, FEC)
- UniUDP REPE integration
- Fleet API (TCP and UniUDP multi-server control)

### Run C++ Integration Tests

```bash
cd test
./run_glaze_test.sh
```

This script automatically:
1. Starts the C++ REPE server
2. Runs Julia client tests against it
3. Verifies protocol compatibility
4. Cleans up the server process

## License

MIT License - See LICENSE file for details

## References

- [REPE Specification](https://github.com/repe-org/REPE)
- [Glaze C++ Library](https://github.com/stephenberry/glaze)
