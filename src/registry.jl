"""
    Registry

A registry for serving variables and functions via REPE using JSON pointer syntax.

The registry allows:
- Reading variables via JSON pointer paths (empty body = read)
- Writing variables via JSON pointer paths (non-empty body = write)
- Calling functions with the body as input arguments

This matches the behavior of the Glaze C++ REPE registry.
"""
mutable struct Registry
    data::Dict{String, Any}

    function Registry()
        new(Dict{String, Any}())
    end

    function Registry(data::Dict{String, Any})
        new(data)
    end

    function Registry(pairs::Pair{String, <:Any}...)
        new(Dict{String, Any}(pairs...))
    end
end

# Allow indexing into the registry
Base.getindex(r::Registry, key::String) = r.data[key]
Base.setindex!(r::Registry, value, key::String) = (r.data[key] = value)
Base.haskey(r::Registry, key::String) = haskey(r.data, key)
Base.keys(r::Registry) = keys(r.data)
Base.values(r::Registry) = values(r.data)
Base.delete!(r::Registry, key::String) = delete!(r.data, key)
Base.length(r::Registry) = length(r.data)
Base.isempty(r::Registry) = isempty(r.data)

"""
    merge!(registry::Registry, dict::AbstractDict)
    merge!(registry::Registry, path::String, dict::AbstractDict)
    merge!(registry::Registry, pairs...)

Merge a dictionary or key-value pairs into the registry.

When a path is provided, the dictionary is merged at that path (creating nested
structure as needed). This allows registering an entire dictionary under a root path.

# Examples
```julia
registry = Registry("x" => 1)

# Merge at root
merge!(registry, Dict("y" => 2, "z" => 3))
merge!(registry, "a" => 10, "b" => 20)

# Merge at a specific path
api_handlers = Dict(
    "users" => Dict("list" => () -> [...]),
    "posts" => Dict("create" => (;title, body) -> ...)
)
merge!(registry, "/api", api_handlers)
# Now accessible as /api/users/list, /api/posts/create, etc.
```
"""
function Base.merge!(r::Registry, dict::AbstractDict)
    for (k, v) in dict
        r.data[string(k)] = v
    end
    return r
end

function Base.merge!(r::Registry, path::String, dict::AbstractDict)
    # Parse the path to get segments
    segments = parse_json_pointer("/" * lstrip(path, '/'))

    if isempty(segments)
        # Merging at root - same as merge!(r, dict)
        return merge!(r, dict)
    end

    # Navigate to or create the target location
    current = r.data
    for segment in segments
        if !haskey(current, segment)
            current[segment] = Dict{String, Any}()
        end
        target = current[segment]
        if !(target isa Dict)
            # Convert non-dict to dict if needed, or error
            current[segment] = Dict{String, Any}()
        end
        current = current[segment]
    end

    # Merge the dict entries at this location
    for (k, v) in dict
        current[string(k)] = v
    end

    return r
end

function Base.merge!(r::Registry, pairs::Pair...)
    for (k, v) in pairs
        r.data[string(k)] = v
    end
    return r
end

"""
    merge(registry::Registry, dict::AbstractDict)

Create a new registry by merging a dictionary into the existing registry.

# Examples
```julia
registry = Registry("x" => 1)
new_registry = merge(registry, Dict("y" => 2))
```
"""
function Base.merge(r::Registry, dict::AbstractDict)
    new_registry = Registry(copy(r.data))
    merge!(new_registry, dict)
    return new_registry
end

"""
    parse_json_pointer(pointer::String) -> Vector{String}

Parse a JSON pointer string (RFC 6901) into path segments.

# Examples
```julia
parse_json_pointer("/employees/0/name")  # Returns ["employees", "0", "name"]
parse_json_pointer("/")                   # Returns []
parse_json_pointer("")                    # Returns []
```
"""
function parse_json_pointer(pointer::String)::Vector{String}
    if isempty(pointer) || pointer == "/"
        return String[]
    end

    # JSON pointer must start with /
    if !startswith(pointer, "/")
        throw(ArgumentError("JSON pointer must start with '/' or be empty"))
    end

    # Remove leading slash and split by '/'
    segments = split(pointer[2:end], '/')

    # Unescape JSON pointer special characters (RFC 6901)
    # ~1 -> /  (must be done first)
    # ~0 -> ~
    return [replace(replace(String(segment), "~1" => "/"), "~0" => "~") for segment in segments]
end

"""
    resolve_json_pointer(obj, pointer::String)
    resolve_json_pointer(obj, segments::Vector{String})

Resolve a JSON pointer path against an object, returning the value at that path.

Supports:
- Dict access by key
- Array/Vector access by 0-based index
- Struct field access by name

# Examples
```julia
data = Dict("users" => [Dict("name" => "Alice"), Dict("name" => "Bob")])
resolve_json_pointer(data, "/users/0/name")  # Returns "Alice"
```
"""
function resolve_json_pointer(obj, pointer::String)
    segments = parse_json_pointer(pointer)
    return resolve_json_pointer(obj, segments)
end

function resolve_json_pointer(obj, segments::Vector{String})
    current = obj

    # For Registry, access the underlying data dict
    if current isa Registry
        current = current.data
    end

    # If segments is empty, return the data (for Registry this is the data dict, not the struct)
    if isempty(segments)
        return current
    end

    for segment in segments
        current = _access_segment(current, segment)
    end

    return current
end

"""
    _access_segment(obj, segment::String)

Access a single segment (key, index, or field) on an object.
"""
function _access_segment(obj, segment::String)
    if obj isa Dict
        # Try string key first, then symbol
        if haskey(obj, segment)
            return obj[segment]
        elseif haskey(obj, Symbol(segment))
            return obj[Symbol(segment)]
        else
            throw(KeyError("Key '$segment' not found in Dict"))
        end
    elseif obj isa AbstractVector || obj isa AbstractArray
        # JSON pointer uses 0-based indexing
        index = tryparse(Int, segment)
        if index === nothing
            throw(ArgumentError("Invalid array index '$segment'"))
        end
        julia_index = index + 1  # Convert to 1-based
        if julia_index < 1 || julia_index > length(obj)
            throw(BoundsError(obj, julia_index))
        end
        return obj[julia_index]
    elseif obj isa Registry
        return obj.data[segment]
    else
        # Try struct field access
        sym = Symbol(segment)
        if hasfield(typeof(obj), sym)
            return getfield(obj, sym)
        else
            throw(ArgumentError("Cannot access '$segment' on object of type $(typeof(obj))"))
        end
    end
end

"""
    set_json_pointer!(obj, pointer::String, value)
    set_json_pointer!(obj, segments::Vector{String}, value)

Set a value at the given JSON pointer path in an object.

# Examples
```julia
data = Dict("config" => Dict("timeout" => 30))
set_json_pointer!(data, "/config/timeout", 60)
```
"""
function set_json_pointer!(obj, pointer::String, value)
    segments = parse_json_pointer(pointer)
    return set_json_pointer!(obj, segments, value)
end

function set_json_pointer!(obj, segments::Vector{String}, value)
    if isempty(segments)
        throw(ArgumentError("Cannot set root object via JSON pointer"))
    end

    # Navigate to the parent of the target
    parent = obj

    # For Registry, access the underlying data dict
    if parent isa Registry
        parent = parent.data
    end

    for segment in segments[1:end-1]
        parent = _access_segment(parent, segment)
    end

    # Set the final value
    final_segment = segments[end]
    _set_segment!(parent, final_segment, value)

    return value
end

"""
    _set_segment!(obj, segment::String, value)

Set a value at a single segment (key, index, or field) on an object.
"""
function _set_segment!(obj, segment::String, value)
    if obj isa Dict
        obj[segment] = value
    elseif obj isa AbstractVector || obj isa AbstractArray
        index = tryparse(Int, segment)
        if index === nothing
            throw(ArgumentError("Invalid array index '$segment'"))
        end
        julia_index = index + 1  # Convert to 1-based
        if julia_index < 1 || julia_index > length(obj)
            throw(BoundsError(obj, julia_index))
        end
        obj[julia_index] = value
    elseif obj isa Registry
        obj.data[segment] = value
    else
        # Try to set struct field - only works for mutable structs
        sym = Symbol(segment)
        if hasfield(typeof(obj), sym)
            if ismutabletype(typeof(obj))
                setfield!(obj, sym, value)
            else
                throw(ArgumentError("Cannot set field '$segment' on immutable struct $(typeof(obj))"))
            end
        else
            throw(ArgumentError("Cannot set '$segment' on object of type $(typeof(obj))"))
        end
    end
end

"""
    handle_registry_request(registry::Registry, request::Message)::Message

Process a REPE request against a registry.

Behavior:
- Empty body: READ the value at the JSON pointer path
- Non-empty body with Function at path: CALL the function with body as arguments
- Non-empty body with non-Function at path: WRITE the body value to that path

This matches the Glaze C++ REPE registry semantics.
"""
function handle_registry_request(registry::Registry, request::Message)::Message
    try
        pointer = parse_query(request)
        body_empty = isempty(request.body)

        if body_empty
            # READ operation
            result = resolve_json_pointer(registry, pointer)

            # If result is a function with no body, we can't call it (no args)
            # Just return info about it
            if result isa Function
                return create_response(request, Dict(
                    "type" => "function",
                    "path" => pointer
                ))
            end

            return create_response(request, result)
        else
            # Non-empty body - check what's at the path
            params = parse_body(request)

            # Try to resolve the path to see what's there
            target = try
                resolve_json_pointer(registry, pointer)
            catch
                nothing
            end

            if target isa Function
                # CALL the function with body as arguments
                result = _invoke_function(target, params)
                return create_response(request, result)
            else
                # WRITE operation - set the value at the path
                if isempty(pointer) || pointer == "/"
                    # Writing to root - params must be a Dict to merge/replace
                    if params isa Dict
                        for (k, v) in params
                            registry.data[string(k)] = v
                        end
                    else
                        throw(ArgumentError("Cannot write non-Dict to registry root"))
                    end
                else
                    set_json_pointer!(registry, pointer, params)
                end

                return create_response(request, Dict("status" => "ok", "path" => pointer))
            end
        end

    catch e
        error_msg = string(e)
        @error "Registry request error" exception = e
        return _create_registry_error_response(request, error_msg)
    end
end

"""
    _invoke_function(f::Function, params)

Invoke a function with the given parameters.

Supports:
- Dict params: passed as keyword arguments or single dict argument
- Array params: passed as positional arguments
- Single value: passed as single argument
- nothing: called with no arguments
"""
function _invoke_function(f::Function, params)
    if params === nothing
        return f()
    elseif _is_dict_like(params)
        # Check if dict is empty
        if isempty(params)
            return f()
        end
        # Try to call with keyword arguments first
        try
            kwargs = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in pairs(params))
            return f(; kwargs...)
        catch e
            # If kwargs fails, try passing dict as single argument
            if e isa MethodError
                return f(params)
            end
            rethrow(e)
        end
    elseif params isa AbstractVector
        return f(params...)
    else
        return f(params)
    end
end

# Helper to check if something is dict-like (handles JSON.Object etc.)
function _is_dict_like(x)
    return x isa AbstractDict || (hasproperty(x, :keys) && hasproperty(x, :values) && applicable(pairs, x))
end

function _create_registry_error_response(request::Message, msg::String)::Message
    return Message(
        id=request.header.id,
        query=request.query,
        body=msg,
        query_format=request.header.query_format,
        body_format=UInt16(BODY_UTF8),
        ec=UInt32(EC_PARSE_ERROR)
    )
end

"""
    serve(server::Server, registry::Registry; path_prefix::String="")

Configure a Server to serve a Registry.

All requests to the server will be handled by the registry using JSON pointer
semantics. The query field is treated as a JSON pointer into the registry.

# Arguments
- `server`: The REPE server to configure
- `registry`: The registry to serve
- `path_prefix`: Optional prefix to strip from queries (e.g., "/api")

# Examples
```julia
registry = Registry(
    "config" => Dict("timeout" => 30, "retries" => 3),
    "add" => (a, b) -> a + b,
    "multiply" => (x, y) -> x * y
)

server = Server("localhost", 8080)
serve(server, registry)
listen(server)
```
"""
function serve(server::Server, registry::Registry; path_prefix::String="")
    # Use middleware to intercept all requests
    use(server, function(request::Message)
        query = parse_query(request)

        # Strip path prefix if specified
        if !isempty(path_prefix) && startswith(query, path_prefix)
            # Create a new request with modified query
            new_query = query[length(path_prefix)+1:end]
            if isempty(new_query)
                new_query = "/"
            end
            modified_request = Message(
                id=request.header.id,
                query=new_query,
                body=request.body,
                query_format=request.header.query_format,
                body_format=request.header.body_format,
                notify=request.header.notify != 0,
                ec=request.header.ec
            )
            return handle_registry_request(registry, modified_request)
        end

        return handle_registry_request(registry, request)
    end)
end

"""
    register!(registry::Registry, path::String, value)

Register a value or function at the given path in the registry.

# Examples
```julia
registry = Registry()
register!(registry, "counter", 0)
register!(registry, "increment", () -> (registry["counter"] += 1; registry["counter"]))
register!(registry, "add", (a, b) -> a + b)
```
"""
function register!(registry::Registry, path::String, value)
    # Handle nested paths
    segments = parse_json_pointer("/" * lstrip(path, '/'))

    if isempty(segments)
        throw(ArgumentError("Cannot register at root path"))
    end

    if length(segments) == 1
        registry.data[segments[1]] = value
    else
        # Create nested structure if needed
        current = registry.data
        for segment in segments[1:end-1]
            if !haskey(current, segment)
                current[segment] = Dict{String, Any}()
            end
            current = current[segment]
        end
        current[segments[end]] = value
    end

    return registry
end

# Pretty printing
function Base.show(io::IO, r::Registry)
    n_entries = length(r.data)
    entry_text = n_entries == 1 ? "1 entry" : "$n_entries entries"
    print(io, "Registry($entry_text)")
end

function Base.show(io::IO, ::MIME"text/plain", r::Registry)
    println(io, "Registry with $(length(r.data)) entries:")
    for (k, v) in r.data
        if v isa Function
            println(io, "  /$k => <function>")
        elseif v isa Dict
            println(io, "  /$k => Dict($(length(v)) entries)")
        elseif v isa AbstractVector
            println(io, "  /$k => $(typeof(v))($(length(v)) elements)")
        else
            println(io, "  /$k => $v")
        end
    end
end
