mutable struct Header
    length::UInt64
    spec::UInt16
    version::UInt8
    notify::UInt8
    reserved::UInt32
    id::UInt64
    query_length::UInt64
    body_length::UInt64
    query_format::UInt16
    body_format::UInt16
    ec::UInt32
    
    function Header(;
        length::Union{UInt64, Int} = 0,
        spec::Union{UInt16, Int} = REPE_SPEC,
        version::Union{UInt8, Int} = REPE_VERSION,
        notify::Union{UInt8, Int} = 0,
        reserved::Union{UInt32, Int} = 0,
        id::Union{UInt64, Int} = 0,
        query_length::Union{UInt64, Int} = 0,
        body_length::Union{UInt64, Int} = 0,
        query_format::Union{UInt16, Int} = UInt16(QUERY_RAW_BINARY),
        body_format::Union{UInt16, Int} = UInt16(BODY_RAW_BINARY),
        ec::Union{UInt32, Int} = UInt32(EC_OK)
    )
        new(UInt64(length), UInt16(spec), UInt8(version), UInt8(notify), 
            UInt32(reserved), UInt64(id), UInt64(query_length), UInt64(body_length), 
            UInt16(query_format), UInt16(body_format), UInt32(ec))
    end
end

function serialize_header(header::Header)::Vector{UInt8}
    buffer = Vector{UInt8}(undef, HEADER_SIZE)
    
    offset = 1
    buffer[offset:offset+7] = reinterpret(UInt8, [header.length])
    offset += 8
    
    buffer[offset:offset+1] = reinterpret(UInt8, [header.spec])
    offset += 2
    
    buffer[offset] = header.version
    offset += 1
    
    buffer[offset] = header.notify
    offset += 1
    
    buffer[offset:offset+3] = reinterpret(UInt8, [header.reserved])
    offset += 4
    
    buffer[offset:offset+7] = reinterpret(UInt8, [header.id])
    offset += 8
    
    buffer[offset:offset+7] = reinterpret(UInt8, [header.query_length])
    offset += 8
    
    buffer[offset:offset+7] = reinterpret(UInt8, [header.body_length])
    offset += 8
    
    buffer[offset:offset+1] = reinterpret(UInt8, [header.query_format])
    offset += 2
    
    buffer[offset:offset+1] = reinterpret(UInt8, [header.body_format])
    offset += 2
    
    buffer[offset:offset+3] = reinterpret(UInt8, [header.ec])
    
    return buffer
end

function deserialize_header(buffer::Vector{UInt8})::Header
    if length(buffer) < HEADER_SIZE
        throw(ArgumentError("Buffer too small for REPE header"))
    end
    
    header = Header()
    
    offset = 1
    header.length = reinterpret(UInt64, buffer[offset:offset+7])[1]
    offset += 8
    
    header.spec = reinterpret(UInt16, buffer[offset:offset+1])[1]
    offset += 2
    
    if header.spec != REPE_SPEC
        throw(ArgumentError("Invalid REPE spec: $(header.spec)"))
    end
    
    header.version = buffer[offset]
    offset += 1
    
    if header.version != REPE_VERSION
        throw(ArgumentError("Unsupported REPE version: $(header.version)"))
    end
    
    header.notify = buffer[offset]
    offset += 1
    
    header.reserved = reinterpret(UInt32, buffer[offset:offset+3])[1]
    offset += 4
    
    header.id = reinterpret(UInt64, buffer[offset:offset+7])[1]
    offset += 8
    
    header.query_length = reinterpret(UInt64, buffer[offset:offset+7])[1]
    offset += 8
    
    header.body_length = reinterpret(UInt64, buffer[offset:offset+7])[1]
    offset += 8
    
    header.query_format = reinterpret(UInt16, buffer[offset:offset+1])[1]
    offset += 2
    
    header.body_format = reinterpret(UInt16, buffer[offset:offset+1])[1]
    offset += 2
    
    header.ec = reinterpret(UInt32, buffer[offset:offset+3])[1]
    
    expected_length = HEADER_SIZE + header.query_length + header.body_length
    if header.length != expected_length
        throw(ArgumentError("Header length mismatch: expected $expected_length, got $(header.length)"))
    end
    
    return header
end

function validate_header(header::Header)::Bool
    if header.spec != REPE_SPEC
        return false
    end
    
    if header.version != REPE_VERSION
        return false
    end
    
    if header.reserved != 0
        return false
    end
    
    expected_length = HEADER_SIZE + header.query_length + header.body_length
    if header.length != expected_length
        return false
    end
    
    return true
end