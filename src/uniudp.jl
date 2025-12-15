# UniUDP - Unidirectional UDP protocol with chunking, redundancy, and FEC
# Provides reliable message delivery over one-way UDP links

module UniUDP

using Sockets
using Base.Threads: Atomic, atomic_add!

export send_message, receive_message, MessageReport, SAFE_UDP_PAYLOAD, clear_message_state!

const DEFAULT_CHUNK_SIZE = 1024
const HEADER_LENGTH = 30  # 64-bit message_id (8) + chunk_index (4) + total_chunks (4) + message_length (4) + chunk_size (2) + payload_len (2) + redundancy (2) + attempt (2) + fec_field (2)
const FEC_PARITY_FLAG = UInt16(0x0001)
const MAX_FEC_GROUP_SIZE = UInt16(0x7fff)
const SAFE_UDP_PAYLOAD = 1452  # Conservative MTU: fits IPv6 over standard Ethernet
const MESSAGE_COUNTER = Atomic{UInt64}(rand(UInt64))  # Random initialization for collision avoidance

# Deduplication: track recently completed message IDs to prevent duplicate returns
const COMPLETED_MESSAGES = Dict{UInt64, Float64}()  # message_id => completion_time
const COMPLETED_MESSAGES_LOCK = ReentrantLock()
const DEDUP_WINDOW = 10.0  # seconds to remember completed messages

# Concurrent message assembly: buffer chunks from multiple in-flight messages
# (Initialized after MessageState is defined)

"""
    socket_fd(sock::UDPSocket) -> Cint

Get the underlying file descriptor from a UDPSocket using libuv's uv_fileno.
"""
function socket_fd(sock::UDPSocket)
    fdval = Ref{Cint}(0)
    ret = ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ref{Cint}), sock.handle, fdval)
    ret != 0 && error("uv_fileno failed: unable to get socket file descriptor")
    return fdval[]
end

mutable struct PacketHeader
    message_id::UInt64
    chunk_index::UInt32
    total_chunks::UInt32
    message_length::UInt32
    chunk_size::UInt16
    payload_len::UInt16
    redundancy::UInt16
    attempt::UInt16
    fec_field::UInt16
end

@inline function pack_fec_field(group_size::UInt16, is_parity::Bool)
    group_size == UInt16(0) && throw(ArgumentError("fec_group_size must be positive"))
    group_size > MAX_FEC_GROUP_SIZE && throw(ArgumentError("fec_group_size exceeds encodable range"))
    field = UInt16(group_size << 1)
    is_parity && (field = field | FEC_PARITY_FLAG)
    return field
end

@inline fec_is_parity(field::UInt16) = (field & FEC_PARITY_FLAG) != 0

@inline function fec_group_size_from_field(field::UInt16)
    size = field >> 1
    size == UInt16(0) && return 1
    return Int(size)
end

"""
    MessageReport

Holds the result of `receive_message`, including the reconstructed payload, bookkeeping
about chunk delivery, and redundancy reporting.

`completion_reason` reports why `receive_message` stopped listening. Possible values
include `:completed`, `:inactivity_timeout`, and `:overall_timeout`. `fec_group_size`
captures the negotiated parity block size, and `fec_recovered_chunks` lists any
zero-based chunk indices reconstructed from parity.
"""
struct MessageReport
    message_id::UInt64
    payload::Vector{UInt8}
    chunks_expected::Int
    chunks_received::Int
    lost_chunks::Vector{Int}
    redundancy_requested::Int
    redundancy_required::Int
    fec_group_size::Int
    fec_recovered_chunks::Vector{Int}
    source::Sockets.InetAddr
    completion_reason::Symbol
end

mutable struct MessageState
    message_id::UInt64
    total_chunks::Int
    chunk_size::Int
    message_length::Int
    redundancy::Int
    fec_group_size::Int
    chunks::Vector{Union{Nothing,Vector{UInt8}}}
    chunk_lengths::Vector{Int}
    min_attempt::Vector{Int}
    parity_chunks::Vector{Union{Nothing,Vector{UInt8}}}
    parity_attempts::Vector{Int}
    fec_recovered::Vector{Int}
    source::Sockets.InetAddr
    created_at::Float64
end

function MessageState(header::PacketHeader, payload::Vector{UInt8}, source::Sockets.InetAddr)
    total_chunks = Int(header.total_chunks)
    total_chunks <= 0 && throw(ArgumentError("total_chunks must be positive"))
    message_length = Int(header.message_length)
    message_length < 0 && throw(ArgumentError("message_length must be non-negative"))
    chunk_size = Int(header.chunk_size)
    chunk_size <= 0 && throw(ArgumentError("chunk_size must be positive"))
    redundancy = Int(header.redundancy)
    redundancy < 1 && throw(ArgumentError("redundancy must be at least 1"))
    message_length > chunk_size * total_chunks && throw(ArgumentError("message_length exceeds chunk budget"))
    fec_group_size = fec_group_size_from_field(header.fec_field)
    fec_group_size < 1 && throw(ArgumentError("fec_group_size must be at least 1"))
    parity_slots = cld(total_chunks, fec_group_size)
    chunks = Vector{Union{Nothing,Vector{UInt8}}}(undef, total_chunks)
    fill!(chunks, nothing)
    chunk_lengths = fill(0, total_chunks)
    min_attempt = fill(redundancy + 1, total_chunks)
    parity_chunks = Vector{Union{Nothing,Vector{UInt8}}}(undef, parity_slots)
    fill!(parity_chunks, nothing)
    parity_attempts = fill(redundancy + 1, parity_slots)
    fec_recovered = Int[]
    state = MessageState(header.message_id, total_chunks, chunk_size, message_length,
                         redundancy, fec_group_size, chunks, chunk_lengths, min_attempt,
                         parity_chunks, parity_attempts, fec_recovered, source, time())
    update_state!(state, header, payload)
    return state
end

# Now that MessageState is defined, create the pending messages buffer
const PENDING_MESSAGES = Dict{UInt64, MessageState}()
const PENDING_MESSAGES_LOCK = ReentrantLock()
const MAX_PENDING_MESSAGES = 100  # Maximum number of concurrent messages to buffer
const PENDING_MAX_AGE = 30.0  # seconds before stale pending messages are evicted

@inline function next_message_id()
    return atomic_add!(MESSAGE_COUNTER, UInt64(1))
end

# --- Deduplication helpers ---

"""
    is_duplicate(message_id::UInt64) -> Bool

Check if a message ID has already been completed within the deduplication window.
"""
function is_duplicate(message_id::UInt64)
    lock(COMPLETED_MESSAGES_LOCK) do
        haskey(COMPLETED_MESSAGES, message_id)
    end
end

"""
    mark_completed!(message_id::UInt64)

Mark a message ID as completed for deduplication purposes.
"""
function mark_completed!(message_id::UInt64)
    lock(COMPLETED_MESSAGES_LOCK) do
        COMPLETED_MESSAGES[message_id] = time()
    end
end

"""
    cleanup_completed!()

Remove expired entries from the completed messages cache.
"""
function cleanup_completed!()
    cutoff = time() - DEDUP_WINDOW
    lock(COMPLETED_MESSAGES_LOCK) do
        filter!(kv -> kv.second > cutoff, COMPLETED_MESSAGES)
    end
end

# --- Concurrent message buffer helpers ---

"""
    get_or_create_state!(message_id::UInt64, header::PacketHeader, payload::Vector{UInt8}, source::Sockets.InetAddr) -> MessageState

Get an existing MessageState for the given message_id, or create a new one.
"""
function get_or_create_state!(message_id::UInt64, header::PacketHeader, payload::Vector{UInt8}, source::Sockets.InetAddr)
    lock(PENDING_MESSAGES_LOCK) do
        if haskey(PENDING_MESSAGES, message_id)
            state = PENDING_MESSAGES[message_id]
            update_state!(state, header, payload; source=source)
            return state
        else
            state = MessageState(header, payload, source)
            PENDING_MESSAGES[message_id] = state
            return state
        end
    end
end

"""
    remove_pending!(message_id::UInt64)

Remove a message from the pending buffer after completion.
"""
function remove_pending!(message_id::UInt64)
    lock(PENDING_MESSAGES_LOCK) do
        delete!(PENDING_MESSAGES, message_id)
    end
end

"""
    find_complete_message(filter_id::Union{Nothing,UInt64}) -> Union{Nothing, MessageState}

Find and remove a completed message from the pending buffer.
If filter_id is provided, only check that specific message.
"""
function find_complete_message(filter_id::Union{Nothing,UInt64})
    lock(PENDING_MESSAGES_LOCK) do
        if filter_id !== nothing
            if haskey(PENDING_MESSAGES, filter_id)
                state = PENDING_MESSAGES[filter_id]
                if message_complete(state)
                    delete!(PENDING_MESSAGES, filter_id)
                    return state
                end
            end
            return nothing
        end
        # Find any complete message
        for (mid, state) in PENDING_MESSAGES
            if message_complete(state)
                delete!(PENDING_MESSAGES, mid)
                return state
            end
        end
        return nothing
    end
end

"""
    cleanup_pending!(max_age::Float64 = PENDING_MAX_AGE)

Remove stale incomplete messages from the pending buffer based on age.
"""
function cleanup_pending!(max_age::Float64 = PENDING_MAX_AGE)
    cutoff = time() - max_age
    lock(PENDING_MESSAGES_LOCK) do
        filter!(kv -> kv.second.created_at > cutoff, PENDING_MESSAGES)
    end
end

"""
    clear_message_state!()

Clear all global message state (deduplication cache and pending messages buffer).
Useful for testing to ensure clean state between tests.
"""
function clear_message_state!()
    lock(COMPLETED_MESSAGES_LOCK) do
        empty!(COMPLETED_MESSAGES)
    end
    lock(PENDING_MESSAGES_LOCK) do
        empty!(PENDING_MESSAGES)
    end
end

"""
    send_message(sock, host, port, data; redundancy=1, chunk_size=1024, fec_group_size=1,
                  delay=0.0, message_id=next_message_id())

Transmit `data` to `(host, port)` using the unidirectional UDP protocol defined by UniUDP.
The payload is split into fixed-size chunks, and each chunk is sent `redundancy` times to
mitigate datagram loss. The function returns the message identifier used for the transfer.

`data` may be an `AbstractVector{UInt8}` or a string; strings are sent using their UTF-8
bytes. A `delay` (in seconds) can be introduced between redundant transmissions to help
spread the traffic if desired.
"""
function send_message(sock::UDPSocket, host, port::Integer, data::AbstractVector{UInt8};
                      redundancy::Integer = 1, chunk_size::Integer = DEFAULT_CHUNK_SIZE,
                      fec_group_size::Integer = 1, delay::Real = 0.0,
                      message_id::UInt64 = next_message_id())
    redundancy < 1 && throw(ArgumentError("redundancy must be at least 1"))
    chunk_size < 1 && throw(ArgumentError("chunk_size must be positive"))
    redundancy > typemax(UInt16) && throw(ArgumentError("redundancy exceeds UInt16 capacity"))
    chunk_size > typemax(UInt16) && throw(ArgumentError("chunk_size exceeds UInt16 capacity"))
    fec_group_size < 1 && throw(ArgumentError("fec_group_size must be at least 1"))
    fec_group_size > Int(MAX_FEC_GROUP_SIZE) && throw(ArgumentError("fec_group_size exceeds encodable range"))

    packet_size = chunk_size + HEADER_LENGTH
    packet_size > SAFE_UDP_PAYLOAD &&
        @warn "Packet size $packet_size exceeds safe MTU ($SAFE_UDP_PAYLOAD), risking IP fragmentation"

    data_length = length(data)
    message_length = data_length
    total_chunks = cld(data_length, chunk_size)
    total_chunks == 0 && (total_chunks = 1)
    total_chunks > typemax(UInt32) && throw(ArgumentError("payload too large"))
    message_length > chunk_size * total_chunks && throw(ArgumentError("payload size inconsistent with chunk metadata"))

    fec_group_u16 = UInt16(fec_group_size)
    data_field = pack_fec_field(fec_group_u16, false)
    parity_field = pack_fec_field(fec_group_u16, true)
    fec_enabled = fec_group_size > 1

    buffer = Vector{UInt8}(undef, HEADER_LENGTH + chunk_size)
    parity_buffer = fec_enabled ? Vector{UInt8}(undef, chunk_size) : UInt8[]

    for chunk_idx in 0:(total_chunks - 1)
        start_idx = chunk_idx * chunk_size + 1
        stop_idx = min(start_idx + chunk_size - 1, data_length)
        payload_len = stop_idx - start_idx + 1
        payload_len = max(payload_len, 0)

        header = PacketHeader(message_id, UInt32(chunk_idx), UInt32(total_chunks),
                              UInt32(message_length), UInt16(chunk_size), UInt16(payload_len),
                              UInt16(redundancy), UInt16(0), data_field)

        for attempt in 1:redundancy
            write_packet!(buffer, header, data, start_idx, payload_len, attempt)
            send(sock, host, port, buffer[1:(HEADER_LENGTH + payload_len)])
            delay > 0 && sleep(delay)
        end

        if fec_enabled
            group_offset = chunk_idx % fec_group_size
            if group_offset == 0
                fill!(parity_buffer, 0x00)
            end
            if payload_len > 0
                # XOR payload into parity buffer
                @inbounds for i in 1:payload_len
                    parity_buffer[i] = xor(parity_buffer[i], data[start_idx + i - 1])
                end
            end
            if group_offset == (fec_group_size - 1) || chunk_idx == (total_chunks - 1)
                # Parity uses full chunk_size; shorter final chunks are implicitly zero-padded
                # (parity_buffer is zero-initialized). Recovery trims to expected length.
                group_start = chunk_idx - group_offset
                parity_header = PacketHeader(message_id, UInt32(group_start), UInt32(total_chunks),
                                             UInt32(message_length), UInt16(chunk_size), UInt16(chunk_size),
                                             UInt16(redundancy), UInt16(0), parity_field)
                for attempt in 1:redundancy
                    write_packet!(buffer, parity_header, parity_buffer, 1, chunk_size, attempt)
                    send(sock, host, port, buffer[1:(HEADER_LENGTH + chunk_size)])
                    delay > 0 && sleep(delay)
                end
            end
        end
    end
    return message_id
end

function send_message(sock::UDPSocket, host, port::Integer, data::AbstractString; kwargs...)
    send_message(sock, host, port, Vector{UInt8}(codeunits(data)); kwargs...)
end

"""
    send_message(host, port, data; kwargs...)

Convenience method that creates a temporary socket, sends the message, and cleans up.
Returns the message ID used for the transfer. See the full signature for available options.
"""
function send_message(host, port::Integer, data; kwargs...)
    sock = UDPSocket()
    try
        bind(sock, ip"0.0.0.0", 0)
        return send_message(sock, host, port, data; kwargs...)
    finally
        close(sock)
    end
end

"""
    receive_message(sock; message_id=nothing, inactivity_timeout=0.2, overall_timeout=5.0)

Collect a single UniUDP message from `sock` and return a `MessageReport`. The receiver
waits for packets with matching message identifiers until all chunks are reconstructed,
an inactivity period elapses, or the `overall_timeout` is exceeded.

If `message_id` is provided, only that specific message will be returned. Packets from
other message IDs are buffered and can be retrieved by subsequent calls.

When `message_id` is `nothing`, returns the first complete message from any sender.
This supports concurrent message assembly - chunks from multiple in-flight messages
are buffered simultaneously.

Deduplication: Messages that have already been returned within the deduplication window
($(DEDUP_WINDOW) seconds) are automatically filtered out, preventing duplicate returns
when redundancy > 1.

`MessageReport.lost_chunks` lists zero-based chunk indices that never arrived, and
`MessageReport.redundancy_required` reports the highest attempt number observed across
delivered chunks—effectively the redundancy level that was actually needed.
`MessageReport.completion_reason` indicates whether reception ended because all chunks
arrived, inactivity elapsed, or the overall timeout was exceeded.
"""
function receive_message(sock::UDPSocket; message_id::Union{Nothing,UInt64} = nothing,
                         inactivity_timeout::Real = 0.2, overall_timeout::Real = 5.0)
    overall_timeout <= 0 && throw(ArgumentError("overall_timeout must be positive"))
    inactivity_timeout <= 0 && throw(ArgumentError("inactivity_timeout must be positive"))

    # Periodically clean up old entries
    cleanup_completed!()
    cleanup_pending!()

    start_time = time()
    reason::Symbol = :unknown

    while true
        # Check if we already have a complete message buffered
        complete_state = find_complete_message(message_id)
        if complete_state !== nothing
            # Check deduplication - skip if already returned
            if is_duplicate(complete_state.message_id)
                # Already returned this message, remove from buffer and continue
                continue
            end
            # Mark as completed for deduplication
            mark_completed!(complete_state.message_id)
            reason = :completed
            return build_report(complete_state, reason)
        end

        # Check timeouts
        elapsed = time() - start_time
        if elapsed >= overall_timeout
            reason = :overall_timeout
            break
        end

        # Wait for next packet
        wait_time = min(inactivity_timeout, overall_timeout - elapsed)
        next_packet = recvfrom_timeout(sock, wait_time)

        if next_packet === nothing
            # Inactivity timeout - check if we have partial data for requested message
            if message_id !== nothing
                partial_state = lock(PENDING_MESSAGES_LOCK) do
                    get(PENDING_MESSAGES, message_id, nothing)
                end
                if partial_state !== nothing
                    reason = :inactivity_timeout
                    lock(PENDING_MESSAGES_LOCK) do
                        delete!(PENDING_MESSAGES, message_id)
                    end
                    return build_report(partial_state, reason)
                end
            end
            reason = :inactivity_timeout
            break
        end

        src, packet = next_packet
        local header, payload
        try
            header, payload = parse_packet(packet)
        catch err
            @warn "Discarding packet that failed to parse" exception=(err, catch_backtrace())
            continue
        end

        # Skip packets for already-completed messages (deduplication)
        if is_duplicate(header.message_id)
            continue
        end

        # Buffer this chunk (concurrent message assembly)
        state = get_or_create_state!(header.message_id, header, payload, src)

        # Check if this message is now complete
        if message_complete(state)
            # If we're filtering by message_id and this isn't it, keep it buffered
            if message_id !== nothing && state.message_id != message_id
                continue
            end

            # Remove from pending buffer
            remove_pending!(state.message_id)

            # Mark as completed for deduplication
            mark_completed!(state.message_id)

            reason = :completed
            return build_report(state, reason)
        end
    end

    # Timeout with no complete message
    # If filtering by message_id, try to return partial data
    if message_id !== nothing
        partial_state = lock(PENDING_MESSAGES_LOCK) do
            state = get(PENDING_MESSAGES, message_id, nothing)
            if state !== nothing
                delete!(PENDING_MESSAGES, message_id)
            end
            state
        end
        if partial_state !== nothing
            return build_report(partial_state, reason)
        end
    end

    throw(ErrorException("timeout exceeded before first packet"))
end

"""
    build_report(state::MessageState, reason::Symbol) -> MessageReport

Build a MessageReport from a MessageState.
"""
function build_report(state::MessageState, reason::Symbol)
    lost = collect_lost(state)
    payload = collect_payload(state)
    redundancy_required = isempty(lost) ? maximum(state.min_attempt) : state.redundancy + 1
    return MessageReport(state.message_id, payload, state.total_chunks,
                         count(!isnothing, state.chunks), lost,
                         state.redundancy, redundancy_required, state.fec_group_size,
                         copy(state.fec_recovered), state.source, reason)
end

function update_state!(state::MessageState, header::PacketHeader, payload::Vector{UInt8};
                       source::Sockets.InetAddr = state.source)
    payload_len_declared = Int(header.payload_len)
    payload_len = length(payload)
    if payload_len != payload_len_declared
        @warn "Ignoring packet with mismatched payload length" message_id=state.message_id expected=payload_len_declared observed=payload_len
        return
    end
    if payload_len_declared > state.chunk_size
        @warn "Ignoring packet with payload longer than chunk size" message_id=state.message_id payload_len=payload_len_declared chunk_size=state.chunk_size
        return
    end

    total_chunks = Int(header.total_chunks)
    if total_chunks != state.total_chunks
        @warn "Ignoring packet with mismatched total chunk count" message_id=state.message_id expected=state.total_chunks observed=total_chunks
        return
    end
    chunk_size = Int(header.chunk_size)
    if chunk_size != state.chunk_size
        @warn "Ignoring packet with mismatched chunk size" message_id=state.message_id expected=state.chunk_size observed=chunk_size
        return
    end
    msg_length = Int(header.message_length)
    if msg_length != state.message_length
        @warn "Ignoring packet with mismatched message length" message_id=state.message_id expected=state.message_length observed=msg_length
        return
    end

    redundancy = Int(header.redundancy)
    if redundancy < 1
        @warn "Ignoring packet with invalid redundancy" message_id=state.message_id redundancy=redundancy
        return
    end
    if redundancy != state.redundancy
        @warn "Ignoring packet with mismatched redundancy" message_id=state.message_id expected=state.redundancy observed=redundancy
        return
    end

    attempt = Int(header.attempt)
    if attempt < 1
        @warn "Ignoring packet with invalid attempt number" message_id=state.message_id attempt=attempt
        return
    end
    if attempt > state.redundancy
        @warn "Ignoring packet with attempt exceeding redundancy" message_id=state.message_id attempt=attempt redundancy=state.redundancy
        return
    end

    fec_group_size = fec_group_size_from_field(header.fec_field)
    if fec_group_size != state.fec_group_size
        @warn "Ignoring packet with mismatched FEC group size" message_id=state.message_id expected=state.fec_group_size observed=fec_group_size
        return
    end
    is_parity = fec_is_parity(header.fec_field)

    if is_parity
        group_start = Int(header.chunk_index)
        if group_start < 0 || group_start >= state.total_chunks
            @warn "Ignoring parity packet with out-of-range group start" message_id=state.message_id group_start=group_start total_chunks=state.total_chunks
            return
        end
        if state.fec_group_size == 1
            # No FEC expected but header flagged parity
            @warn "Ignoring unexpected parity packet" message_id=state.message_id chunk_index=group_start
            return
        end
        if group_start % state.fec_group_size != 0
            @warn "Ignoring parity packet with non-aligned group start" message_id=state.message_id group_start=group_start fec_group_size=state.fec_group_size
            return
        end
        group_index = (group_start ÷ state.fec_group_size) + 1
        if group_index < 1 || group_index > length(state.parity_chunks)
            @warn "Ignoring parity packet with invalid group index" message_id=state.message_id group_index=group_index
            return
        end

        stored = state.parity_chunks[group_index]
        if stored === nothing || attempt < state.parity_attempts[group_index]
            parity_vec = Vector{UInt8}(undef, state.chunk_size)
            fill!(parity_vec, 0x00)
            copy_len = min(payload_len, state.chunk_size)
            if copy_len > 0
                copyto!(parity_vec, 1, payload, 1, copy_len)
            end
            state.parity_chunks[group_index] = parity_vec
            state.parity_attempts[group_index] = attempt
        end

        state.source = source
        try_recover_group!(state, group_index)
        return
    end

    chunk_index_raw = Int(header.chunk_index)
    if chunk_index_raw < 0 || chunk_index_raw >= state.total_chunks
        @warn "Ignoring packet with chunk index outside expected range" message_id=state.message_id chunk_index=chunk_index_raw total_chunks=state.total_chunks
        return
    end

    chunk_position = chunk_index_raw + 1
    expected_len = expected_chunk_length(state, chunk_position)
    if payload_len_declared != expected_len
        @warn "Ignoring packet with unexpected payload length" message_id=state.message_id chunk_index=chunk_index_raw expected=expected_len observed=payload_len_declared
        return
    end

    if state.chunks[chunk_position] === nothing
        state.chunks[chunk_position] = payload
        state.chunk_lengths[chunk_position] = payload_len_declared
        state.min_attempt[chunk_position] = min(state.min_attempt[chunk_position], attempt)
    else
        if attempt < state.min_attempt[chunk_position]
            state.min_attempt[chunk_position] = attempt
        end
    end

    state.source = source
    if state.fec_group_size > 1
        group_index = ((chunk_position - 1) ÷ state.fec_group_size) + 1
        try_recover_group!(state, group_index)
    end
    return
end

message_complete(state::MessageState) = all(!isnothing, state.chunks)

@inline function expected_chunk_length(state::MessageState, position::Int)
    position < 1 && throw(ArgumentError("chunk position must be positive"))
    if state.total_chunks == 1
        return state.message_length
    elseif position < state.total_chunks
        return state.chunk_size
    else
        tail = state.message_length - state.chunk_size * (state.total_chunks - 1)
        return max(tail, 0)
    end
end

function try_recover_group!(state::MessageState, group_index::Int)
    state.fec_group_size > 1 || return
    if group_index < 1 || group_index > length(state.parity_chunks)
        return
    end
    parity_vec = state.parity_chunks[group_index]
    parity_vec === nothing && return

    start_pos = (group_index - 1) * state.fec_group_size + 1
    end_pos = min(start_pos + state.fec_group_size - 1, state.total_chunks)

    missing_pos = 0
    parity_copy = copy(parity_vec)

    for pos in start_pos:end_pos
        chunk = state.chunks[pos]
        if chunk === nothing
            if missing_pos != 0
                return
            end
            missing_pos = pos
        else
            len = state.chunk_lengths[pos]
            if len > 0
                @inbounds for i in 1:len
                    parity_copy[i] = xor(parity_copy[i], chunk[i])
                end
            end
        end
    end

    missing_pos == 0 && return

    expected_len = expected_chunk_length(state, missing_pos)
    recovered = expected_len == 0 ? UInt8[] : parity_copy[1:expected_len]
    state.chunks[missing_pos] = recovered
    state.chunk_lengths[missing_pos] = expected_len
    state.min_attempt[missing_pos] = state.redundancy + 1
    push!(state.fec_recovered, missing_pos - 1)
end

function collect_lost(state::MessageState)
    lost = Int[]
    for (idx, chunk) in enumerate(state.chunks)
        chunk === nothing && push!(lost, idx - 1)
    end
    return lost
end

function collect_payload(state::MessageState)
    result = Vector{UInt8}(undef, state.message_length)
    pos = 1
    for (idx, chunk) in enumerate(state.chunks)
        chunk === nothing && continue
        len = state.chunk_lengths[idx]
        len <= 0 && continue
        copy_len = min(len, length(chunk))
        copyto!(result, pos, chunk, 1, copy_len)
        pos += len
    end
    return resize!(result, pos - 1)
end

function write_packet!(buffer::Vector{UInt8}, header::PacketHeader, data::AbstractVector{UInt8},
                       start_idx::Int, payload_len::Int, attempt::Integer)
    header.attempt = UInt16(attempt)
    header.payload_len = UInt16(payload_len)
    write_header!(buffer, header)
    if payload_len > 0
        copyto!(buffer, HEADER_LENGTH + 1, data, start_idx, payload_len)
    end
    return
end

function write_header!(buffer::Vector{UInt8}, header::PacketHeader)
    pos = 1
    pos = write_be!(buffer, pos, header.message_id)
    pos = write_be!(buffer, pos, header.chunk_index)
    pos = write_be!(buffer, pos, header.total_chunks)
    pos = write_be!(buffer, pos, header.message_length)
    pos = write_be!(buffer, pos, header.chunk_size)
    pos = write_be!(buffer, pos, header.payload_len)
    pos = write_be!(buffer, pos, header.redundancy)
    pos = write_be!(buffer, pos, header.attempt)
    pos = write_be!(buffer, pos, header.fec_field)
    return pos
end

function parse_packet(packet::Vector{UInt8})
    length(packet) < HEADER_LENGTH && throw(ArgumentError("packet shorter than expected"))
    pos = 1
    message_id, pos = read_be(packet, pos, UInt64)
    chunk_index, pos = read_be(packet, pos, UInt32)
    total_chunks, pos = read_be(packet, pos, UInt32)
    message_length, pos = read_be(packet, pos, UInt32)
    chunk_size, pos = read_be(packet, pos, UInt16)
    payload_len, pos = read_be(packet, pos, UInt16)
    redundancy, pos = read_be(packet, pos, UInt16)
    attempt, pos = read_be(packet, pos, UInt16)
    fec_field, pos = read_be(packet, pos, UInt16)
    total_len = HEADER_LENGTH + Int(payload_len)
    length(packet) < total_len && throw(ArgumentError("packet shorter than declared payload length"))
    payload_len > chunk_size && throw(ArgumentError("payload length exceeds chunk size declared in header"))
    if payload_len == 0
        payload = UInt8[]
    else
        payload = packet[(HEADER_LENGTH + 1):total_len]
    end
    header = PacketHeader(message_id, chunk_index, total_chunks, message_length,
                          chunk_size, payload_len, redundancy, attempt, fec_field)
    return header, payload
end

# Poll structure for poll(2) syscall
# struct pollfd { int fd; short events; short revents; }
struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end

const POLLIN = Cshort(0x0001)

"""
    poll_socket(sock::UDPSocket, timeout_ms::Integer) -> Bool

Poll a socket for readability with a timeout in milliseconds.
Returns `true` if data is available, `false` on timeout.
Throws an error if poll fails.
"""
function poll_socket(sock::UDPSocket, timeout_ms::Integer)
    fd = socket_fd(sock)
    pfd = Ref(PollFD(fd, POLLIN, Cshort(0)))
    @static if Sys.iswindows()
        # Windows uses WSAPoll with slightly different semantics
        ret = ccall((:WSAPoll, "ws2_32"), Cint, (Ref{PollFD}, Cuint, Cint), pfd, 1, timeout_ms)
    else
        ret = ccall(:poll, Cint, (Ref{PollFD}, Cuint, Cint), pfd, 1, timeout_ms)
    end
    if ret < 0
        error("poll failed: $(Libc.strerror(Libc.errno()))")
    end
    return ret > 0 && (pfd[].revents & POLLIN) != 0
end

"""
    recvfrom_timeout(sock::UDPSocket, timeout::Real)

Receive a UDP datagram with a timeout. Returns `(address, data)` on success,
or `nothing` if the timeout expires. Uses `poll(2)` to check socket readability
before calling `recvfrom`, avoiding issues with libuv's non-blocking I/O model.

The implementation uses short poll intervals with `yield()` calls to allow
Julia's task scheduler to run other tasks (important for async send/receive tests).
"""
function recvfrom_timeout(sock::UDPSocket, timeout::Real)
    timeout <= 0 && return nothing
    !isfinite(timeout) && throw(ArgumentError("timeout must be finite"))

    # Use short poll intervals to allow Julia's scheduler to run other tasks
    # This is critical for async scenarios where sender/receiver run concurrently
    deadline = time() + timeout
    poll_interval_ms = 10  # Short interval for responsiveness

    while true
        remaining = deadline - time()
        remaining <= 0 && return nothing

        current_ms = min(poll_interval_ms, round(Int, remaining * 1000))
        current_ms = max(current_ms, 1)  # At least 1ms

        if poll_socket(sock, current_ms)
            # Data is available, safe to call recvfrom (won't block)
            return recvfrom(sock)
        end

        # Yield to allow other tasks (like async senders) to run
        yield()
    end
end

function write_be!(buffer::Vector{UInt8}, pos::Int, value::UInt16)
    buffer[pos] = UInt8(value >>> 8)
    buffer[pos + 1] = UInt8(value & 0xff)
    return pos + 2
end

function write_be!(buffer::Vector{UInt8}, pos::Int, value::UInt32)
    hi = UInt16(value >>> 16)
    lo = UInt16(value & 0xffff)
    pos = write_be!(buffer, pos, hi)
    pos = write_be!(buffer, pos, lo)
    return pos
end

function write_be!(buffer::Vector{UInt8}, pos::Int, value::UInt64)
    hi = UInt32(value >>> 32)
    lo = UInt32(value & 0xffffffff)
    pos = write_be!(buffer, pos, hi)
    pos = write_be!(buffer, pos, lo)
    return pos
end

function read_be(buffer::Vector{UInt8}, pos::Int, ::Type{UInt16})
    byte1 = buffer[pos]
    byte2 = buffer[pos + 1]
    value = (UInt16(byte1) << 8) | UInt16(byte2)
    return value, pos + 2
end

function read_be(buffer::Vector{UInt8}, pos::Int, ::Type{UInt32})
    upper, pos = read_be(buffer, pos, UInt16)
    lower, pos = read_be(buffer, pos, UInt16)
    value = (UInt32(upper) << 16) | UInt32(lower)
    return value, pos
end

function read_be(buffer::Vector{UInt8}, pos::Int, ::Type{UInt64})
    upper, pos = read_be(buffer, pos, UInt32)
    lower, pos = read_be(buffer, pos, UInt32)
    value = (UInt64(upper) << 32) | UInt64(lower)
    return value, pos
end

end # module UniUDP
