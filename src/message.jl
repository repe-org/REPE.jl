struct REPEMessage
    header::REPEHeader
    query::Vector{UInt8}
    body::Vector{UInt8}
    
    function REPEMessage(header::REPEHeader, query::Vector{UInt8}, body::Vector{UInt8})
        if length(query) != header.query_length
            throw(ArgumentError("Query length mismatch"))
        end
        if length(body) != header.body_length
            throw(ArgumentError("Body length mismatch"))
        end
        new(header, query, body)
    end
end

function REPEMessage(;
    id::Union{UInt64, Int} = 0,
    query::Union{String, Vector{UInt8}} = UInt8[],
    body::Any = nothing,
    query_format::Union{UInt16, Int} = UInt16(QUERY_RAW_BINARY),
    body_format::Union{UInt16, Int} = UInt16(BODY_RAW_BINARY),
    notify::Bool = false,
    ec::Union{UInt32, Int} = UInt32(EC_OK)
)
    query_bytes = query isa String ? Vector{UInt8}(query) : query
    
    if body === nothing
        body_bytes = UInt8[]
    elseif body isa String
        body_bytes = Vector{UInt8}(body)
    elseif body isa Vector{UInt8}
        body_bytes = body
    else
        # Handle other types - encode based on format
        if body_format == UInt16(BODY_JSON)
            json_str = JSON3.write(body)
            body_bytes = Vector{UInt8}(json_str)
        elseif body_format == UInt16(BODY_BEVE)
            body_bytes = BEVE.to_beve(body)
        else
            body_bytes = Vector{UInt8}(string(body))
        end
    end
    
    query_length = UInt64(length(query_bytes))
    body_length = UInt64(length(body_bytes))
    total_length = HEADER_SIZE + query_length + body_length
    
    header = REPEHeader(
        length = total_length,
        id = UInt64(id),
        query_length = query_length,
        body_length = body_length,
        query_format = UInt16(query_format),
        body_format = UInt16(body_format),
        notify = notify ? 0x01 : 0x00,
        ec = UInt32(ec)
    )
    
    return REPEMessage(header, query_bytes, body_bytes)
end

function serialize_message(msg::REPEMessage)::Vector{UInt8}
    header_bytes = serialize_header(msg.header)
    
    total_size = HEADER_SIZE + length(msg.query) + length(msg.body)
    buffer = Vector{UInt8}(undef, total_size)
    
    buffer[1:HEADER_SIZE] = header_bytes
    
    offset = HEADER_SIZE + 1
    if !isempty(msg.query)
        buffer[offset:offset+length(msg.query)-1] = msg.query
        offset += length(msg.query)
    end
    
    if !isempty(msg.body)
        buffer[offset:offset+length(msg.body)-1] = msg.body
    end
    
    return buffer
end

function deserialize_message(buffer::Vector{UInt8})::REPEMessage
    if length(buffer) < HEADER_SIZE
        throw(ArgumentError("Buffer too small for REPE message"))
    end
    
    header = deserialize_header(buffer[1:HEADER_SIZE])
    
    expected_size = HEADER_SIZE + header.query_length + header.body_length
    if length(buffer) < expected_size
        throw(ArgumentError("Buffer too small: expected $expected_size, got $(length(buffer))"))
    end
    
    offset = HEADER_SIZE + 1
    query = buffer[offset:offset+header.query_length-1]
    
    offset += header.query_length
    body = buffer[offset:offset+header.body_length-1]
    
    return REPEMessage(header, query, body)
end

function parse_query(msg::REPEMessage)::String
    if msg.header.query_format == UInt16(QUERY_JSON_POINTER)
        return String(msg.query)
    elseif msg.header.query_format == UInt16(QUERY_RAW_BINARY)
        return String(msg.query)
    else
        return String(msg.query)
    end
end

function parse_body(msg::REPEMessage)
    if msg.header.body_format == UInt16(BODY_JSON)
        return JSON3.read(msg.body)
    elseif msg.header.body_format == UInt16(BODY_BEVE)
        return BEVE.from_beve(msg.body)
    elseif msg.header.body_format == UInt16(BODY_UTF8)
        return String(msg.body)
    elseif msg.header.body_format == UInt16(BODY_RAW_BINARY)
        return msg.body
    else
        return msg.body
    end
end

function encode_body(data, format::BodyFormat)::Vector{UInt8}
    if format == BODY_JSON
        json_str = JSON3.write(data)
        return Vector{UInt8}(json_str)
    elseif format == BODY_BEVE
        return BEVE.to_beve(data)
    elseif format == BODY_UTF8
        return Vector{UInt8}(string(data))
    elseif format == BODY_RAW_BINARY
        if data isa Vector{UInt8}
            return data
        else
            throw(ArgumentError("Raw binary format requires Vector{UInt8} data"))
        end
    else
        if data isa Vector{UInt8}
            return data
        else
            return Vector{UInt8}(string(data))
        end
    end
end

function create_error_message(ec::ErrorCode, msg::String = "")::REPEMessage
    error_msg = isempty(msg) ? get(ERROR_MESSAGES, ec, "Unknown error") : msg
    
    return REPEMessage(
        query = "",
        body = error_msg,
        body_format = UInt16(BODY_UTF8),
        ec = UInt32(ec)
    )
end

function create_response(request::REPEMessage, result; body_format::BodyFormat = BODY_JSON)::REPEMessage
    body_bytes = encode_body(result, body_format)
    
    return REPEMessage(
        id = request.header.id,
        query = request.query,
        body = body_bytes,
        query_format = request.header.query_format,
        body_format = UInt16(body_format),
        ec = UInt32(EC_OK)
    )
end