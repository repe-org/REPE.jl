# UniUDP protocol unit tests
# Tests for the underlying UDP chunking/redundancy/FEC protocol

using Test
using Sockets
using REPE: UniUDP

const HEADER = UniUDP.HEADER_LENGTH

function bind_local(socket::UDPSocket; host=ip"127.0.0.1", first_port::Int=20000, count::Int=2000)
    for port in first_port:(first_port + count)
        try
            bind(socket, host, port)
            return host, port
        catch err
            err isa Base.IOError || rethrow(err)
        end
    end
    error("Unable to bind UDP socket to a local port in range")
end

@testset "UniUDP Protocol" begin

@testset "send_message emits parity packets" begin
    sender = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        payload = [UInt8(i % 0x100) for i in 0:63]
        chunk_size = 8
        fec_group_size = 3
        redundancy = 1
        total_chunks = cld(length(payload), chunk_size)
        parity_chunks = cld(total_chunks, fec_group_size)
        data_needed = total_chunks * redundancy
        parity_needed = parity_chunks * redundancy

        send_task = @async UniUDP.send_message(sender, host, port, payload;
                                               redundancy=redundancy, chunk_size=chunk_size,
                                               fec_group_size=fec_group_size)

        parity_seen = 0
        data_seen = 0
        attempts = 0
        max_packets = (data_needed + parity_needed) * 2
        group_starts = Int[]
        while (parity_seen < parity_needed || data_seen < data_needed) && attempts < max_packets
            _, packet = recvfrom(receiver)
            attempts += 1
            header, _ = UniUDP.parse_packet(packet)
            if UniUDP.fec_is_parity(header.fec_field)
                parity_seen += 1
                push!(group_starts, Int(header.chunk_index))
            else
                data_seen += 1
                @test header.fec_field == UniUDP.pack_fec_field(UInt16(fec_group_size), false)
            end
        end

        wait(send_task)
        expected_starts = [Int((g - 1) * fec_group_size) for g in 1:parity_chunks]
        @test parity_seen == parity_needed
        @test data_seen == data_needed
        @test sort(group_starts) == expected_starts
    finally
        close(sender)
        close(receiver)
    end
end

function make_packet(message_id::UInt64, chunk_idx::UInt32, total_chunks::UInt32,
                     chunk_size::UInt16, redundancy::UInt16, attempt::UInt16,
                     payload::Vector{UInt8}; message_length::Int = Int(chunk_size) * Int(total_chunks),
                     fec_group_size::Int = 1, parity::Bool = false)
    fec_field = UniUDP.pack_fec_field(UInt16(fec_group_size), parity)
    header = UniUDP.PacketHeader(message_id, chunk_idx, total_chunks, UInt32(message_length),
                                 chunk_size, UInt16(length(payload)), redundancy, attempt, fec_field)
    buffer = Vector{UInt8}(undef, HEADER + length(payload))
    data = payload
    UniUDP.write_packet!(buffer, header, data, 1, length(payload), attempt)
    return buffer[1:(HEADER + length(payload))]
end

function parity_payload(chunks::Vector{Vector{UInt8}}, chunk_size::Int)
    buf = fill(UInt8(0x00), chunk_size)
    for chunk in chunks
        @inbounds for i in 1:length(chunk)
            buf[i] = xor(buf[i], chunk[i])
        end
    end
    return buf
end

@testset "UniUDP packet encoding and parsing" begin
    payload = UInt8[0x10, 0x20, 0x30, 0x40]
    pkt = make_packet(UInt64(0x01020304), UInt32(0), UInt32(1), UInt16(4), UInt16(2), UInt16(1), payload)
    header, decoded = UniUDP.parse_packet(pkt)
    @test header.message_id == UInt64(0x01020304)
    @test header.chunk_index == 0
    @test header.total_chunks == 1
    @test header.redundancy == 2
    @test header.attempt == 1
    @test decoded == payload
end

@testset "Message reconstruction with redundancy" begin
    message = collect(UInt8(0x41):UInt8(0x48)) # 8 bytes
    message_id = UInt64(0x0A0B0C0D)
    chunk_size = UInt16(4)
    redundancy = UInt16(3)
    source = Sockets.InetAddr(ip"127.0.0.1", 9000)

    first_packet = make_packet(message_id, UInt32(0), UInt32(2), chunk_size, redundancy, UInt16(2), message[1:4])
    header, payload = UniUDP.parse_packet(first_packet)
    state = UniUDP.MessageState(header, payload, source)

    second_packet = make_packet(message_id, UInt32(1), UInt32(2), chunk_size, redundancy, UInt16(1), message[5:8])
    header2, payload2 = UniUDP.parse_packet(second_packet)
    UniUDP.update_state!(state, header2, payload2; source=source)

    @test UniUDP.collect_lost(state) == Int[]
    @test UniUDP.collect_payload(state) == message
    @test maximum(state.min_attempt) == 2
end

@testset "Loss detection when redundancy insufficient" begin
    message = UInt8[0xCA, 0xFE, 0xBA, 0xBE]
    message_id = UInt64(0x12345678)
    chunk_size = UInt16(2)
    redundancy = UInt16(2)
    source = Sockets.InetAddr(ip"127.0.0.1", 9100)

    packet = make_packet(message_id, UInt32(0), UInt32(2), chunk_size, redundancy, UInt16(1), message[1:2])
    header, payload = UniUDP.parse_packet(packet)
    state = UniUDP.MessageState(header, payload, source)

    lost = UniUDP.collect_lost(state)
    @test lost == [1]
    @test UniUDP.collect_payload(state) == message[1:2]
    @test maximum(state.min_attempt) == 1 + Int(redundancy)
end

@testset "Out-of-order chunk assembly" begin
    message_id = UInt64(0x0BADF00D)
    chunk_size = UInt16(2)
    redundancy = UInt16(2)
    source = Sockets.InetAddr(ip"127.0.0.1", 9200)

    second_packet = make_packet(message_id, UInt32(1), UInt32(2), chunk_size, redundancy, UInt16(1), UInt8[0x30, 0x31])
    header2, payload2 = UniUDP.parse_packet(second_packet)
    state = UniUDP.MessageState(header2, payload2, source)

    first_packet = make_packet(message_id, UInt32(0), UInt32(2), chunk_size, redundancy, UInt16(2), UInt8[0x10, 0x11])
    header1, payload1 = UniUDP.parse_packet(first_packet)
    UniUDP.update_state!(state, header1, payload1; source=source)

    @test UniUDP.collect_lost(state) == Int[]
    @test UniUDP.collect_payload(state) == UInt8[0x10, 0x11, 0x30, 0x31]
    @test maximum(state.min_attempt) == 2
end

@testset "Header invariant warnings" begin
    message_id = UInt64(0x0F0E0D0C)
    chunk_size = UInt16(4)
    redundancy = UInt16(3)
    source = Sockets.InetAddr(ip"127.0.0.1", 9300)

    function fresh_state()
        first_packet = make_packet(message_id, UInt32(0), UInt32(2), chunk_size, redundancy, UInt16(1), UInt8[0xAA, 0xBB, 0xCC, 0xDD])
        header, payload = UniUDP.parse_packet(first_packet)
        return UniUDP.MessageState(header, payload, source)
    end

    base_packet = make_packet(message_id, UInt32(1), UInt32(2), chunk_size, redundancy, UInt16(1), UInt8[0x11, 0x22, 0x33, 0x44])

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.chunk_size = UInt16(chunk_size + 1)
    @test_logs (:warn, r"mismatched chunk size") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.redundancy = UInt16(redundancy - 1)
    @test_logs (:warn, r"mismatched redundancy") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.attempt = UInt16(redundancy + 1)
    @test_logs (:warn, r"attempt exceeding redundancy") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.chunk_index = UInt32(5)
    @test_logs (:warn, r"chunk index outside expected range") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.payload_len = UInt16(length(payload) + 1)
    @test_logs (:warn, r"mismatched payload length") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.message_length = UInt32(Int(chunk_size) * 3)
    @test_logs (:warn, r"mismatched message length") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    state = fresh_state()
    header, payload = UniUDP.parse_packet(base_packet)
    header.fec_field = UniUDP.pack_fec_field(UInt16(2), false)
    @test_logs (:warn, r"mismatched FEC group size") begin
        UniUDP.update_state!(state, header, payload; source=source)
    end

    parity_packet = make_packet(message_id, UInt32(0), UInt32(2), chunk_size, redundancy, UInt16(1),
                                fill(UInt8(0x00), Int(chunk_size)); parity=true)
    parity_header, parity_payload_data = UniUDP.parse_packet(parity_packet)
    state = fresh_state()
    @test_logs (:warn, r"unexpected parity packet") begin
        UniUDP.update_state!(state, parity_header, parity_payload_data; source=source)
    end

    fec_message_id = message_id + UInt64(1)
    fec_total_chunks = UInt32(4)
    first_fec_packet = make_packet(
        fec_message_id,
        UInt32(0),
        fec_total_chunks,
        chunk_size,
        redundancy,
        UInt16(1),
        UInt8[0x01, 0x02, 0x03, 0x04];
        message_length = Int(chunk_size) * Int(fec_total_chunks),
        fec_group_size = 2,
    )
    fec_header, fec_payload = UniUDP.parse_packet(first_fec_packet)
    fec_state = UniUDP.MessageState(fec_header, fec_payload, source)

    misaligned_parity_packet = make_packet(
        fec_message_id,
        UInt32(1),
        fec_total_chunks,
        chunk_size,
        redundancy,
        UInt16(1),
        fill(UInt8(0x00), Int(chunk_size));
        message_length = Int(chunk_size) * Int(fec_total_chunks),
        fec_group_size = 2,
        parity = true,
    )
    misaligned_header, misaligned_payload = UniUDP.parse_packet(misaligned_parity_packet)
    @test_logs (:warn, r"non-aligned group start") begin
        UniUDP.update_state!(fec_state, misaligned_header, misaligned_payload; source=source)
    end
end

@testset "parse_packet rejects oversize payload" begin
    payload = UInt8[0x01, 0x02, 0x03, 0x04]
    pkt = make_packet(UInt64(0x00000001), UInt32(0), UInt32(1), UInt16(2), UInt16(1), UInt16(1), payload)
    @test_throws ArgumentError UniUDP.parse_packet(pkt)
end

@testset "FEC parity recovers missing chunk" begin
    message_id = UInt64(0xFEC0_0001)
    chunk_size = UInt16(4)
    redundancy = UInt16(1)
    fec_group_size = 2
    total_chunks = UInt32(3)
    message_length = Int(chunk_size) * (Int(total_chunks) - 1) + 2
    source = Sockets.InetAddr(ip"127.0.0.1", 9400)

    chunk0 = UInt8[0x01, 0x02, 0x03, 0x04]
    chunk1 = UInt8[0x10, 0x11, 0x12, 0x13]
    chunk2 = UInt8[0xAA, 0xBB]

    first_packet = make_packet(
        message_id,
        UInt32(0),
        total_chunks,
        chunk_size,
        redundancy,
        UInt16(1),
        chunk0;
        message_length = message_length,
        fec_group_size = fec_group_size,
    )
    header0, payload0 = UniUDP.parse_packet(first_packet)
    state = UniUDP.MessageState(header0, payload0, source)

    third_packet = make_packet(
        message_id,
        UInt32(2),
        total_chunks,
        chunk_size,
        redundancy,
        UInt16(1),
        chunk2;
        message_length = message_length,
        fec_group_size = fec_group_size,
    )
    header2, payload2 = UniUDP.parse_packet(third_packet)
    UniUDP.update_state!(state, header2, payload2; source=source)

    parity_bytes = parity_payload([chunk0, chunk1], Int(chunk_size))
    parity_packet = make_packet(
        message_id,
        UInt32(0),
        total_chunks,
        chunk_size,
        redundancy,
        UInt16(1),
        parity_bytes;
        message_length = message_length,
        fec_group_size = fec_group_size,
        parity = true,
    )
    parity_header, parity_payload_vec = UniUDP.parse_packet(parity_packet)
    UniUDP.update_state!(state, parity_header, parity_payload_vec; source=source)

    @test UniUDP.collect_lost(state) == Int[]
    @test UniUDP.message_complete(state)
    @test state.fec_recovered == [1]
    @test UniUDP.collect_payload(state) == vcat(chunk0, chunk1, chunk2)
    @test maximum(state.min_attempt) == Int(redundancy) + 1
end

@testset "Zero-length payload delivery" begin
    sender = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        payload = UInt8[]
        send_task = @async UniUDP.send_message(sender, host, port, payload; redundancy=2, chunk_size=64)
        report = UniUDP.receive_message(receiver; inactivity_timeout=0.2, overall_timeout=1.0)
        message_id = fetch(send_task)

        @test isempty(report.payload)
        @test report.message_id == message_id
        @test report.lost_chunks == Int[]
        @test report.chunks_expected == 1
        @test report.chunks_received == 1
        @test report.redundancy_requested == 2
        @test report.redundancy_required == 1
        @test report.fec_group_size == 1
        @test isempty(report.fec_recovered_chunks)
        @test report.completion_reason == :completed
    finally
        close(sender)
        close(receiver)
    end
end

@testset "Caller-supplied message id" begin
    sender = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        payload = [UInt8(0x55), UInt8(0x66), UInt8(0x77)]
        explicit_id = UInt64(0xDEADBEEF)
        send_task = @async UniUDP.send_message(sender, host, port, payload; redundancy=1, chunk_size=32, message_id=explicit_id)
        report = UniUDP.receive_message(receiver; inactivity_timeout=0.2, overall_timeout=1.0)
        returned_id = fetch(send_task)

        @test returned_id == explicit_id
        @test report.message_id == explicit_id
        @test report.payload == payload
        @test report.fec_group_size == 1
        @test isempty(report.fec_recovered_chunks)
        @test report.completion_reason == :completed
    finally
        close(sender)
        close(receiver)
    end
end

@testset "End-to-end send and receive" begin
    sender = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        payload = [UInt8(i % 0x100) for i in 0:2047]
        send_task = @async UniUDP.send_message(sender, host, port, payload; redundancy=3, chunk_size=256)
        report = UniUDP.receive_message(receiver; inactivity_timeout=0.2, overall_timeout=5.0)
        wait(send_task)

        @test report.lost_chunks == Int[]
        @test report.redundancy_requested == 3
        @test report.redundancy_required == 1
        @test report.payload == payload
        @test report.chunks_expected == report.chunks_received
        @test report.fec_group_size == 1
        @test isempty(report.fec_recovered_chunks)
        @test report.completion_reason == :completed
    finally
        close(sender)
        close(receiver)
    end
end

@testset "recvfrom_timeout" begin
    @testset "returns nothing on timeout" begin
        sock = UDPSocket()
        try
            bind(sock, ip"127.0.0.1", 0)
            start = time()
            result = UniUDP.recvfrom_timeout(sock, 0.15)
            elapsed = time() - start
            @test result === nothing
            @test elapsed >= 0.1  # Should wait at least most of the timeout
            @test elapsed < 0.5   # Should not wait too long
        finally
            close(sock)
        end
    end

    @testset "returns nothing for zero/negative timeout" begin
        sock = UDPSocket()
        try
            bind(sock, ip"127.0.0.1", 0)
            @test UniUDP.recvfrom_timeout(sock, 0.0) === nothing
            @test UniUDP.recvfrom_timeout(sock, -1.0) === nothing
        finally
            close(sock)
        end
    end

    @testset "throws on non-finite timeout" begin
        sock = UDPSocket()
        try
            bind(sock, ip"127.0.0.1", 0)
            @test_throws ArgumentError UniUDP.recvfrom_timeout(sock, Inf)
            @test_throws ArgumentError UniUDP.recvfrom_timeout(sock, NaN)
        finally
            close(sock)
        end
    end

    @testset "receives data when available" begin
        receiver = UDPSocket()
        sender = UDPSocket()
        try
            host, port = bind_local(receiver)
            bind(sender, ip"127.0.0.1", 0)

            test_data = UInt8[0xDE, 0xAD, 0xBE, 0xEF]
            send(sender, host, port, test_data)

            # Small delay to ensure packet arrives
            sleep(0.01)

            result = UniUDP.recvfrom_timeout(receiver, 1.0)
            @test result !== nothing
            addr, data = result
            @test data == test_data
        finally
            close(receiver)
            close(sender)
        end
    end

    @testset "socket remains usable after timeout" begin
        receiver = UDPSocket()
        sender = UDPSocket()
        try
            host, port = bind_local(receiver)
            bind(sender, ip"127.0.0.1", 0)

            # First, let it timeout
            result1 = UniUDP.recvfrom_timeout(receiver, 0.05)
            @test result1 === nothing

            # Now send data and verify we can still receive
            test_data = UInt8[0xCA, 0xFE]
            send(sender, host, port, test_data)
            sleep(0.01)

            result2 = UniUDP.recvfrom_timeout(receiver, 1.0)
            @test result2 !== nothing
            _, data = result2
            @test data == test_data
        finally
            close(receiver)
            close(sender)
        end
    end
end

@testset "poll_socket" begin
    sock = UDPSocket()
    sender = UDPSocket()
    try
        host, port = bind_local(sock)
        bind(sender, ip"127.0.0.1", 0)

        # Should return false when no data available
        @test UniUDP.poll_socket(sock, 10) == false

        # Should return true when data is available
        send(sender, host, port, UInt8[0x01, 0x02])
        sleep(0.01)
        @test UniUDP.poll_socket(sock, 100) == true
    finally
        close(sock)
        close(sender)
    end
end

@testset "Large message (1000+ chunks)" begin
    sender = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        # 100KB payload with 64-byte chunks = 1600 chunks
        payload = [UInt8(i % 0x100) for i in 1:102400]
        chunk_size = 64
        expected_chunks = cld(length(payload), chunk_size)
        @test expected_chunks == 1600

        send_task = @async UniUDP.send_message(sender, host, port, payload;
                                               redundancy=1, chunk_size=chunk_size)
        report = UniUDP.receive_message(receiver; inactivity_timeout=0.5, overall_timeout=10.0)
        wait(send_task)

        @test report.payload == payload
        @test report.chunks_expected == expected_chunks
        @test report.chunks_received == expected_chunks
        @test report.lost_chunks == Int[]
        @test report.completion_reason == :completed
    finally
        close(sender)
        close(receiver)
    end
end

@testset "High loss simulation with FEC recovery" begin
    sender = UDPSocket()
    dropper = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender, ip"127.0.0.1", 0)
        drop_host, drop_port = bind_local(dropper)
        recv_host, recv_port = bind_local(receiver; first_port=21000)

        payload = [UInt8(i % 0x100) for i in 1:256]
        chunk_size = 32
        fec_group_size = 4
        redundancy = 1
        total_chunks = cld(length(payload), chunk_size)

        # Drop ~25% of data packets (1 per FEC group), rely on FEC recovery
        drop_task = @async begin
            dropped_in_group = Dict{Int,Bool}()
            packets_seen = 0
            parity_groups = cld(total_chunks, fec_group_size)
            expected_packets = (total_chunks + parity_groups) * redundancy

            while packets_seen < expected_packets
                _, packet = recvfrom(dropper)
                packets_seen += 1
                header, _ = UniUDP.parse_packet(packet)

                if !UniUDP.fec_is_parity(header.fec_field)
                    chunk_idx = Int(header.chunk_index)
                    group = chunk_idx ÷ fec_group_size
                    # Drop first data packet of each group
                    if !get(dropped_in_group, group, false)
                        dropped_in_group[group] = true
                        continue  # Drop this packet
                    end
                end
                send(dropper, recv_host, recv_port, packet)
            end
        end

        send_task = @async UniUDP.send_message(sender, drop_host, drop_port, payload;
                                               redundancy=redundancy, chunk_size=chunk_size,
                                               fec_group_size=fec_group_size)

        report = UniUDP.receive_message(receiver; inactivity_timeout=0.5, overall_timeout=5.0)
        wait(send_task)
        wait(drop_task)

        @test report.payload == payload
        @test report.lost_chunks == Int[]
        @test length(report.fec_recovered_chunks) > 0  # FEC should have recovered some chunks
        @test report.completion_reason == :completed
    finally
        close(sender)
        close(dropper)
        close(receiver)
    end
end

@testset "Concurrent senders with message_id filtering" begin
    # Clear global state from previous tests
    UniUDP.clear_message_state!()

    sender1 = UDPSocket()
    sender2 = UDPSocket()
    receiver = UDPSocket()
    try
        bind(sender1, ip"127.0.0.1", 0)
        bind(sender2, ip"127.0.0.1", 0)
        host, port = bind_local(receiver)

        payload1 = UInt8[0x11, 0x22, 0x33, 0x44]
        payload2 = UInt8[0xAA, 0xBB, 0xCC, 0xDD]
        id1 = UInt64(0x00000001)
        id2 = UInt64(0x00000002)

        # Send both messages concurrently
        task1 = @async UniUDP.send_message(sender1, host, port, payload1;
                                           redundancy=2, chunk_size=64, message_id=id1)
        task2 = @async UniUDP.send_message(sender2, host, port, payload2;
                                           redundancy=2, chunk_size=64, message_id=id2)

        # Give senders time to start sending
        yield()

        # Receive specifically message 2 (filtering out message 1 packets)
        report2 = UniUDP.receive_message(receiver; message_id=id2,
                                         inactivity_timeout=0.3, overall_timeout=2.0)

        # Now receive message 1
        report1 = UniUDP.receive_message(receiver; message_id=id1,
                                         inactivity_timeout=0.3, overall_timeout=2.0)

        wait(task1)
        wait(task2)

        @test report1.message_id == id1
        @test report1.payload == payload1
        @test report1.completion_reason == :completed

        @test report2.message_id == id2
        @test report2.payload == payload2
        @test report2.completion_reason == :completed
    finally
        close(sender1)
        close(sender2)
        close(receiver)
    end
end

@testset "Convenience send function" begin
    receiver = UDPSocket()
    try
        host, port = bind_local(receiver)

        payload = UInt8[0xDE, 0xAD, 0xBE, 0xEF]
        send_task = @async UniUDP.send_message(host, port, payload; redundancy=2, chunk_size=64)
        report = UniUDP.receive_message(receiver; inactivity_timeout=0.3, overall_timeout=2.0)
        message_id = fetch(send_task)

        @test report.message_id == message_id
        @test report.payload == payload
        @test report.lost_chunks == Int[]
        @test report.completion_reason == :completed
    finally
        close(receiver)
    end
end

@testset "SAFE_UDP_PAYLOAD is exported" begin
    @test UniUDP.SAFE_UDP_PAYLOAD == 1452
    @test UniUDP.SAFE_UDP_PAYLOAD > UniUDP.HEADER_LENGTH + UniUDP.DEFAULT_CHUNK_SIZE
end

end # UniUDP Protocol testset
