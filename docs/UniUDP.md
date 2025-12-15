# UniUDP - Unidirectional UDP Protocol

UniUDP provides a reliable messaging protocol layered on top of unidirectional UDP sockets. It splits payloads into numbered chunks, repeats each chunk according to a configurable redundancy level, and reassembles the stream on the receiver while reporting the effective redundancy that was required to deliver every chunk.

## Features

- Configurable chunk size and redundancy factor when sending
- Optional XOR parity blocks (FEC) to rebuild missing chunks without increasing redundancy
- Automatic message identifier generation or caller-supplied IDs
- Message ID filtering for receiving specific messages when multiple senders share a socket
- Detailed delivery reports: missing chunks, redundancy required, FEC recoveries, completion reason
- MTU-aware: exports `SAFE_UDP_PAYLOAD` (1452 bytes) and warns when packet sizes risk IP fragmentation
- Minimal dependencies: works with Julia's built-in `Sockets` module

## REPE over UniUDP

REPE.jl provides `UniUDPClient` and `UniUDPServer` for sending REPE messages over unidirectional UDP links. This is useful for scenarios like:

- One-way satellite or radio links
- Sensor networks with asymmetric connectivity
- Broadcast/multicast scenarios
- High-throughput logging where acknowledgments aren't needed

### Client Example

```julia
using REPE

# Create client targeting a UniUDP server
client = UniUDPClient(ip"192.168.1.100", 5000;
    redundancy = 2,       # Send each chunk twice
    chunk_size = 1024,    # Bytes per chunk
    fec_group_size = 4    # XOR parity every 4 chunks
)

# Fire-and-forget notification
send_notify(client, "/sensor/temperature", Dict("value" => 23.5))

# Fire-and-forget request (server computes but can't return result)
send_request(client, "/compute/factorial", Dict("n" => 10))

close(client)
```

### Server Example

```julia
using REPE

server = UniUDPServer(5000;
    inactivity_timeout = 0.5,
    overall_timeout = 30.0,
    response_callback = (method, result, msg) -> println("Result: $result")
)

register(server, "/compute/square") do params, msg
    return params["x"]^2  # Result goes to response_callback
end

register(server, "/sensor/reading") do params, msg
    println("Received: $params")  # Notification handling
end

# Start server (blocking)
listen(server)

# Or async
listen(server; async=true)
```

## Raw UniUDP Protocol

For direct access to the UniUDP protocol (without REPE message framing):

```julia
using REPE: UniUDP
using Sockets

receiver = UDPSocket()
bind(receiver, ip"0.0.0.0", 20000)

# Send with temporary socket
@async begin
    payload = [UInt8(i) for i in 0:255]
    UniUDP.send_message(ip"127.0.0.1", 20000, payload;
        redundancy = 3,
        chunk_size = 64,
        fec_group_size = 4
    )
end

report = UniUDP.receive_message(receiver;
    inactivity_timeout = 0.2,
    overall_timeout = 2.0
)

println("Lost chunks: ", report.lost_chunks)
println("Redundancy required: ", report.redundancy_required)
println("FEC recovered chunks: ", report.fec_recovered_chunks)
println("Completion reason: ", report.completion_reason)

close(receiver)
```

### Using Your Own Socket

```julia
sender = UDPSocket()
bind(sender, ip"0.0.0.0", 0)
message_id = UniUDP.send_message(sender, ip"127.0.0.1", 20000, payload;
    redundancy = 2
)
close(sender)
```

### Filtering by Message ID

```julia
# Receive only a specific message when multiple senders share a socket
report = UniUDP.receive_message(receiver;
    message_id = UInt64(0x12345678),
    overall_timeout = 5.0
)
```

## Packet Header Format

Each datagram starts with a fixed 30-byte header encoded in big-endian order, followed by the payload:

```
Byte
Offset   Field
┌──────┬─────────────────────────────────────────┐
│  0   │                                         │
│  :   │           message_id (8 bytes)          │
│  7   │                                         │
├──────┼─────────────────────────────────────────┤
│  8   │                                         │
│  :   │          chunk_index (4 bytes)          │
│ 11   │                                         │
├──────┼─────────────────────────────────────────┤
│ 12   │                                         │
│  :   │          total_chunks (4 bytes)         │
│ 15   │                                         │
├──────┼─────────────────────────────────────────┤
│ 16   │                                         │
│  :   │         message_length (4 bytes)        │
│ 19   │                                         │
├──────┼────────────────────┬────────────────────┤
│ 20   │  chunk_size        │  payload_len       │
│  :   │  (2 bytes)         │  (2 bytes)         │
│ 23   │                    │                    │
├──────┼────────────────────┼────────────────────┤
│ 24   │  redundancy        │  attempt           │
│  :   │  (2 bytes)         │  (2 bytes)         │
│ 27   │                    │                    │
├──────┼────────────────────┴────────────────────┤
│ 28   │           fec_field (2 bytes)           │
│ 29   │                                         │
├──────┼─────────────────────────────────────────┤
│ 30   │                                         │
│  :   │        payload (payload_len bytes)      │
│  :   │                                         │
└──────┴─────────────────────────────────────────┘
```

| Field | Offset | Size | Description |
|-------|--------|------|-------------|
| `message_id` | 0 | 8 bytes | Unique identifier for the logical message |
| `chunk_index` | 8 | 4 bytes | Zero-based index of this chunk |
| `total_chunks` | 12 | 4 bytes | Total number of chunks in the message |
| `message_length` | 16 | 4 bytes | Total payload bytes across entire message |
| `chunk_size` | 20 | 2 bytes | Size allocated for each chunk payload |
| `payload_len` | 22 | 2 bytes | Actual payload bytes in this packet |
| `redundancy` | 24 | 2 bytes | Redundant transmissions requested |
| `attempt` | 26 | 2 bytes | One-based transmission attempt number |
| `fec_field` | 28 | 2 bytes | FEC metadata (see below) |
| `payload` | 30 | variable | Chunk data (`payload_len` bytes) |

**fec_field encoding:**

The 16-bit `fec_field` packs two values:
- **Bit 0 (LSB)**: Parity flag — `1` if this packet is an XOR parity chunk, `0` for data
- **Bits 1-15**: FEC group size — number of data chunks per parity group (1 = FEC disabled)

```
fec_field = (fec_group_size << 1) | parity_flag
```

Packets with invalid metadata are discarded during reassembly and reported via warnings.

## Forward Error Correction (FEC)

Set `fec_group_size > 1` to emit one XOR parity chunk after every `fec_group_size` data chunks. The receiver can reconstruct any single missing chunk per group using the parity data.

```julia
# Example: 4-chunk FEC groups
# Chunks 0, 1, 2, 3 -> Parity P0
# Chunks 4, 5, 6, 7 -> Parity P1
# If chunk 2 is lost, it can be recovered: chunk2 = P0 XOR chunk0 XOR chunk1 XOR chunk3
```

The `MessageReport` includes:
- `fec_group_size`: The negotiated group size
- `fec_recovered_chunks`: Zero-based indices of chunks recovered via parity

### FEC vs Redundancy Trade-offs

| Strategy | Traffic Overhead | Protection |
|----------|-----------------|------------|
| `redundancy=2, fec=1` | 2x | Survives any single packet loss |
| `redundancy=1, fec=4` | 1.25x | Survives one loss per 4-chunk group |
| `redundancy=2, fec=4` | 2.5x | Survives burst losses + isolated losses |

## MessageReport Fields

After receiving a message, the `MessageReport` contains:

| Field | Type | Description |
|-------|------|-------------|
| `message_id` | `UInt64` | Message identifier |
| `payload` | `Vector{UInt8}` | Reconstructed payload |
| `chunks_expected` | `Int` | Total chunks in message |
| `chunks_received` | `Int` | Chunks successfully received |
| `lost_chunks` | `Vector{Int}` | Zero-based indices of missing chunks |
| `redundancy_requested` | `Int` | Sender's redundancy setting |
| `redundancy_required` | `Int` | Highest attempt number observed |
| `fec_group_size` | `Int` | Negotiated FEC group size |
| `fec_recovered_chunks` | `Vector{Int}` | Chunks recovered via parity |
| `source` | `InetAddr` | Sender's address |
| `completion_reason` | `Symbol` | `:completed`, `:inactivity_timeout`, or `:overall_timeout` |

## Constants

- `UniUDP.SAFE_UDP_PAYLOAD` = 1452 bytes (conservative MTU for IPv6 over Ethernet)
- `UniUDP.HEADER_LENGTH` = 30 bytes
- `UniUDP.DEFAULT_CHUNK_SIZE` = 1024 bytes

## Limitations

- **Single chunk recovery**: Parity handles at most one missing chunk per FEC group; burst losses affecting multiple chunks in the same group still result in gaps
- **One message at a time**: Messages are collected sequentially; use `message_id` filtering when multiple senders share a socket
- **No acknowledgments**: The protocol is strictly one-way; there's no back-channel for ACKs
- **MTU warnings**: Setting `chunk_size + 30 > SAFE_UDP_PAYLOAD` risks IP fragmentation; a warning is emitted but transmission proceeds

## Deduplication

The receiver automatically deduplicates messages:
- Completed message IDs are cached for 10 seconds
- Redundant packets for already-completed messages are silently dropped
- Use `UniUDP.clear_message_state!()` to reset the deduplication cache (useful in tests)
