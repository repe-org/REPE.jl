# REPE.jl

Julia implementation of the [REPE (Remote Efficient Protocol Extension)](https://github.com/repe-org/REPE) RPC specification. REPE is a fast and simple binary RPC protocol that supports flexible data formats and query specifications.

## Features

- Full implementation of the official [REPE v1 specification](https://github.com/repe-org/REPE)
- Binary protocol with little-endian encoding
- Support for multiple data formats (JSON, BEVE, UTF-8, raw binary)
- Asynchronous client/server architecture
- Error handling with standardized error codes
- Notification support (fire-and-forget messages)
- Compatible with C++ Glaze implementation
- Comprehensive test suite with 107+ unit tests
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

## Testing

### Run Julia Unit Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

All 107 unit tests should pass, covering:
- Header serialization/deserialization
- Message encoding/decoding (JSON, UTF8, BEVE, binary)
- Client-server communication
- Concurrent/async operations  
- Error handling
- BEVE binary format support

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
