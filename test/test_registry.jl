using Test
using REPE

@testset "Registry" begin

    @testset "JSON Pointer Parsing" begin
        # Basic parsing
        @test REPE.parse_json_pointer("") == String[]
        @test REPE.parse_json_pointer("/") == String[]
        @test REPE.parse_json_pointer("/foo") == ["foo"]
        @test REPE.parse_json_pointer("/foo/bar") == ["foo", "bar"]
        @test REPE.parse_json_pointer("/foo/0/bar") == ["foo", "0", "bar"]

        # Escape sequences (RFC 6901)
        @test REPE.parse_json_pointer("/a~1b") == ["a/b"]      # ~1 -> /
        @test REPE.parse_json_pointer("/m~0n") == ["m~n"]      # ~0 -> ~
        @test REPE.parse_json_pointer("/a~0~1b") == ["a~/b"]   # Combined

        # Invalid pointer (no leading /)
        @test_throws ArgumentError REPE.parse_json_pointer("foo")
    end

    @testset "JSON Pointer Resolution" begin
        data = Dict{String, Any}(
            "name" => "test",
            "config" => Dict{String, Any}(
                "timeout" => 30,
                "retries" => 3
            ),
            "users" => [
                Dict{String, Any}("name" => "Alice", "age" => 30),
                Dict{String, Any}("name" => "Bob", "age" => 25)
            ]
        )

        # Root access
        @test REPE.resolve_json_pointer(data, "") === data
        @test REPE.resolve_json_pointer(data, "/") === data

        # Simple key access
        @test REPE.resolve_json_pointer(data, "/name") == "test"

        # Nested access
        @test REPE.resolve_json_pointer(data, "/config/timeout") == 30

        # Array access (0-based indexing)
        @test REPE.resolve_json_pointer(data, "/users/0/name") == "Alice"
        @test REPE.resolve_json_pointer(data, "/users/1/age") == 25

        # Key not found
        @test_throws KeyError REPE.resolve_json_pointer(data, "/nonexistent")

        # Index out of bounds
        @test_throws BoundsError REPE.resolve_json_pointer(data, "/users/10")
    end

    @testset "JSON Pointer Setting" begin
        data = Dict{String, Any}(
            "name" => "test",
            "config" => Dict{String, Any}(
                "timeout" => 30
            ),
            "items" => [1, 2, 3]
        )

        # Set simple value
        REPE.set_json_pointer!(data, "/name", "updated")
        @test data["name"] == "updated"

        # Set nested value
        REPE.set_json_pointer!(data, "/config/timeout", 60)
        @test data["config"]["timeout"] == 60

        # Set array element (0-based)
        REPE.set_json_pointer!(data, "/items/1", 20)
        @test data["items"][2] == 20  # Julia is 1-based

        # Add new key
        REPE.set_json_pointer!(data, "/config/new_key", "value")
        @test data["config"]["new_key"] == "value"

        # Cannot set root
        @test_throws ArgumentError REPE.set_json_pointer!(data, "", "bad")
    end

    @testset "Registry Creation" begin
        # Empty registry
        r1 = REPE.Registry()
        @test length(collect(keys(r1))) == 0

        # Registry from dict
        r2 = REPE.Registry(Dict{String, Any}("a" => 1, "b" => 2))
        @test r2["a"] == 1
        @test r2["b"] == 2

        # Registry from pairs
        r3 = REPE.Registry("x" => 10, "y" => 20)
        @test r3["x"] == 10
        @test r3["y"] == 20
    end

    @testset "Registry Operations" begin
        r = REPE.Registry()

        # Set and get
        r["counter"] = 0
        @test r["counter"] == 0

        # Check existence
        @test haskey(r, "counter")
        @test !haskey(r, "nonexistent")

        # Delete
        delete!(r, "counter")
        @test !haskey(r, "counter")

        # Length and isempty
        @test isempty(r)
        r["x"] = 1
        @test !isempty(r)
        @test length(r) == 1
    end

    @testset "Registry merge!" begin
        r = REPE.Registry("x" => 1, "y" => 2)

        # Merge a Dict
        merge!(r, Dict("z" => 3, "w" => 4))
        @test r["x"] == 1
        @test r["y"] == 2
        @test r["z"] == 3
        @test r["w"] == 4
        @test length(r) == 4

        # Merge overwrites existing keys
        merge!(r, Dict("x" => 100))
        @test r["x"] == 100

        # Merge with pairs
        merge!(r, "a" => 10, "b" => 20)
        @test r["a"] == 10
        @test r["b"] == 20

        # Merge with Symbol keys (converted to String)
        merge!(r, Dict(:sym_key => "value"))
        @test r["sym_key"] == "value"

        # Merge functions
        merge!(r, Dict("add" => (;a, b) -> a + b))
        @test r["add"](a=2, b=3) == 5
    end

    @testset "Registry merge! with path" begin
        r = REPE.Registry()

        # Merge dict at a path
        api_dict = Dict(
            "users" => Dict("count" => 42),
            "posts" => Dict("count" => 100)
        )
        merge!(r, "/api", api_dict)

        # Check structure was created
        @test haskey(r, "api")
        @test r["api"]["users"]["count"] == 42
        @test r["api"]["posts"]["count"] == 100

        # Access via JSON pointer
        @test REPE.resolve_json_pointer(r, "/api/users/count") == 42
        @test REPE.resolve_json_pointer(r, "/api/posts/count") == 100

        # Merge more at same path (should add to existing)
        merge!(r, "/api", Dict("config" => Dict("timeout" => 30)))
        @test r["api"]["config"]["timeout"] == 30
        @test r["api"]["users"]["count"] == 42  # Still exists

        # Merge at deeper path
        merge!(r, "/api/v2/endpoints", Dict("health" => "/health", "status" => "/status"))
        @test REPE.resolve_json_pointer(r, "/api/v2/endpoints/health") == "/health"

        # Merge with leading slash or without
        r2 = REPE.Registry()
        merge!(r2, "foo/bar", Dict("x" => 1))
        merge!(r2, "/foo/baz", Dict("y" => 2))
        @test REPE.resolve_json_pointer(r2, "/foo/bar/x") == 1
        @test REPE.resolve_json_pointer(r2, "/foo/baz/y") == 2

        # Merge at root path "/" is same as merge at root
        r3 = REPE.Registry()
        merge!(r3, "/", Dict("root_key" => "root_value"))
        @test r3["root_key"] == "root_value"

        # Merge functions at a path
        r4 = REPE.Registry()
        merge!(r4, "/math", Dict(
            "add" => (;a, b) -> a + b,
            "multiply" => (x, y) -> x * y
        ))
        @test r4["math"]["add"](a=2, b=3) == 5
        @test r4["math"]["multiply"](4, 5) == 20
    end

    @testset "Registry merge (non-mutating)" begin
        r1 = REPE.Registry("x" => 1)
        r2 = merge(r1, Dict("y" => 2))

        # Original unchanged
        @test length(r1) == 1
        @test !haskey(r1, "y")

        # New registry has both
        @test r2["x"] == 1
        @test r2["y"] == 2
        @test length(r2) == 2
    end

    @testset "Registry register!" begin
        r = REPE.Registry()

        # Register simple value
        REPE.register!(r, "value", 42)
        @test r["value"] == 42

        # Register with leading slash
        REPE.register!(r, "/other", "test")
        @test r["other"] == "test"

        # Register nested path
        REPE.register!(r, "nested/deep/value", 100)
        @test r["nested"]["deep"]["value"] == 100

        # Register function
        REPE.register!(r, "add", (a, b) -> a + b)
        @test r["add"](2, 3) == 5
    end

    @testset "Registry Request Handling - Read" begin
        r = REPE.Registry(
            "counter" => 42,
            "config" => Dict{String, Any}("timeout" => 30),
            "items" => [1, 2, 3]
        )

        # Read root-level value (empty body)
        req = REPE.Message(
            query="/counter",
            body=nothing,
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp = REPE.handle_registry_request(r, req)
        @test resp.header.ec == UInt32(REPE.EC_OK)
        result = REPE.parse_body(resp)
        @test result == 42

        # Read nested value
        req2 = REPE.Message(
            query="/config/timeout",
            body=nothing,
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp2 = REPE.handle_registry_request(r, req2)
        result2 = REPE.parse_body(resp2)
        @test result2 == 30

        # Read array element
        req3 = REPE.Message(
            query="/items/0",
            body=nothing,
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp3 = REPE.handle_registry_request(r, req3)
        result3 = REPE.parse_body(resp3)
        @test result3 == 1
    end

    @testset "Registry Request Handling - Write" begin
        r = REPE.Registry(
            "counter" => 0,
            "config" => Dict{String, Any}("timeout" => 30)
        )

        # Write to existing path
        req = REPE.Message(
            query="/counter",
            body=Dict("value" => 100),  # Body will be the value
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        # Actually for write, the body IS the new value
        req = REPE.Message(
            query="/counter",
            body=100,
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp = REPE.handle_registry_request(r, req)
        @test resp.header.ec == UInt32(REPE.EC_OK)
        @test r["counter"] == 100

        # Write to nested path
        req2 = REPE.Message(
            query="/config/timeout",
            body=60,
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp2 = REPE.handle_registry_request(r, req2)
        @test resp2.header.ec == UInt32(REPE.EC_OK)
        @test r["config"]["timeout"] == 60
    end

    @testset "Registry Request Handling - Function Calls" begin
        r = REPE.Registry()

        # Function with keyword args
        REPE.register!(r, "add", (;a, b) -> a + b)

        # Call with dict args (kwargs style)
        req = REPE.Message(
            query="/add",
            body=Dict("a" => 5, "b" => 3),
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp = REPE.handle_registry_request(r, req)
        @test resp.header.ec == UInt32(REPE.EC_OK)
        result = REPE.parse_body(resp)
        @test result == 8

        # Function with positional args (array input)
        REPE.register!(r, "multiply", (x, y) -> x * y)
        req2 = REPE.Message(
            query="/multiply",
            body=[4, 7],
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp2 = REPE.handle_registry_request(r, req2)
        result2 = REPE.parse_body(resp2)
        @test result2 == 28

        # Function returning complex data (no args)
        REPE.register!(r, "get_info", () -> Dict("name" => "test", "value" => 42))
        req3 = REPE.Message(
            query="/get_info",
            body=nothing,  # Empty body to read function, returns function info
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp3 = REPE.handle_registry_request(r, req3)
        result3 = REPE.parse_body(resp3)
        @test result3["type"] == "function"  # Reading a function returns info about it

        # Now call it with empty dict
        req4 = REPE.Message(
            query="/get_info",
            body=Dict{String,Any}(),  # Empty dict triggers function call
            query_format=UInt16(REPE.QUERY_JSON_POINTER),
            body_format=UInt16(REPE.BODY_JSON)
        )
        resp4 = REPE.handle_registry_request(r, req4)
        result4 = REPE.parse_body(resp4)
        @test result4["name"] == "test"
        @test result4["value"] == 42
    end

    @testset "Registry with Server Integration" begin
        r = REPE.Registry(
            "counter" => 0,
            "add" => (;a, b) -> a + b  # Use kwargs for dict-based calls
        )

        server = REPE.Server("localhost", 18090)
        REPE.serve(server, r)

        # Start server async
        REPE.listen(server, async=true)
        REPE.wait_for_server("localhost", 18090)

        try
            client = REPE.Client("localhost", 18090)
            REPE.connect(client)

            # Read value
            result = REPE.send_request(client, "/counter", nothing,
                query_format=REPE.QUERY_JSON_POINTER,
                body_format=REPE.BODY_JSON)
            @test result == 0

            # Write value
            result2 = REPE.send_request(client, "/counter", 42,
                query_format=REPE.QUERY_JSON_POINTER,
                body_format=REPE.BODY_JSON)
            @test result2["status"] == "ok"

            # Read back
            result3 = REPE.send_request(client, "/counter", nothing,
                query_format=REPE.QUERY_JSON_POINTER,
                body_format=REPE.BODY_JSON)
            @test result3 == 42

            # Call function with kwargs
            result4 = REPE.send_request(client, "/add", Dict("a" => 10, "b" => 20),
                query_format=REPE.QUERY_JSON_POINTER,
                body_format=REPE.BODY_JSON)
            @test result4 == 30

            REPE.disconnect(client)
        finally
            REPE.stop(server)
        end
    end

end
