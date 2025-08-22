@testset "BEVE Support Tests" begin
    
    @testset "BEVE Message Creation" begin
        data = Dict("number" => 42, "text" => "hello", "array" => [1, 2, 3])
        
        msg = REPE.Message(
            id = 123,
            query = "/test/beve",
            body = data,
            body_format = UInt16(REPE.BODY_BEVE)
        )
        
        @test msg.header.id == 123
        @test String(msg.query) == "/test/beve"
        @test msg.header.body_format == UInt16(REPE.BODY_BEVE)
        @test length(msg.body) > 0
    end
    
    @testset "BEVE Encoding/Decoding" begin
        test_data = Dict(
            "int" => 42,
            "float" => 3.14,
            "string" => "hello world",
            "bool" => true,
            "array" => [1, 2, 3, 4, 5],
            "nested" => Dict("a" => 1, "b" => [10, 20])
        )
        
        # Test encoding
        encoded = REPE.encode_body(test_data, REPE.BODY_BEVE)
        @test encoded isa Vector{UInt8}
        @test length(encoded) > 0
        
        # Test decoding
        msg = REPE.Message(
            query = "/test",
            body = encoded,
            body_format = UInt16(REPE.BODY_BEVE)
        )
        
        decoded = parse_body(msg)
        @test decoded isa Dict
        @test decoded["int"] == 42
        @test decoded["float"] ≈ 3.14
        @test decoded["string"] == "hello world"
        @test decoded["bool"] == true
        @test decoded["array"] == [1, 2, 3, 4, 5]
        @test decoded["nested"]["a"] == 1
        @test decoded["nested"]["b"] == [10, 20]
    end
    
    @testset "BEVE Message Round-trip" begin
        original_data = Dict(
            "user_id" => 12345,
            "username" => "test_user",
            "scores" => [95, 87, 92, 88],
            "metadata" => Dict(
                "created_at" => "2023-01-01",
                "active" => true,
                "settings" => Dict("theme" => "dark", "notifications" => false)
            )
        )
        
        # Create message with BEVE format
        request = REPE.Message(
            id = 456,
            query = "/user/profile",
            body = original_data,
            body_format = UInt16(REPE.BODY_BEVE)
        )
        
        # Serialize and deserialize
        serialized = serialize_message(request)
        deserialized = deserialize_message(serialized)
        
        # Parse the body
        parsed_data = parse_body(deserialized)
        
        # Verify everything matches
        @test deserialized.header.id == request.header.id
        @test String(deserialized.query) == String(request.query)
        @test deserialized.header.body_format == request.header.body_format
        
        @test parsed_data["user_id"] == original_data["user_id"]
        @test parsed_data["username"] == original_data["username"]
        @test parsed_data["scores"] == original_data["scores"]
        @test parsed_data["metadata"]["created_at"] == original_data["metadata"]["created_at"]
        @test parsed_data["metadata"]["active"] == original_data["metadata"]["active"]
        @test parsed_data["metadata"]["settings"]["theme"] == original_data["metadata"]["settings"]["theme"]
        @test parsed_data["metadata"]["settings"]["notifications"] == original_data["metadata"]["settings"]["notifications"]
    end
    
    @testset "BEVE vs JSON Size Comparison" begin
        # Test data that should compress well with BEVE
        data = Dict(
            "matrix" => [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
            "numbers" => collect(1:100),
            "repeated" => fill("test", 20),
            "mixed" => Dict(
                "id" => 123,
                "data" => fill(42.0, 50),
                "flags" => fill(true, 30)
            )
        )
        
        # Encode with both formats
        beve_encoded = REPE.encode_body(data, REPE.BODY_BEVE)
        json_encoded = REPE.encode_body(data, REPE.BODY_JSON)
        
        @test length(beve_encoded) > 0
        @test length(json_encoded) > 0
        
        # BEVE should typically be more compact for structured data
        println("  BEVE size: $(length(beve_encoded)) bytes")
        println("  JSON size: $(length(json_encoded)) bytes")
        println("  BEVE is $(round((1 - length(beve_encoded)/length(json_encoded)) * 100, digits=1))% smaller")
        
        # Verify both decode to the same content
        beve_msg = REPE.Message(query="/test", body=beve_encoded, body_format=UInt16(REPE.BODY_BEVE))
        json_msg = REPE.Message(query="/test", body=json_encoded, body_format=UInt16(REPE.BODY_JSON))
        
        beve_decoded = parse_body(beve_msg)
        json_decoded = parse_body(json_msg)
        
        @test beve_decoded["numbers"] == json_decoded["numbers"]
        @test beve_decoded["repeated"] == json_decoded["repeated"]
        @test length(beve_decoded["matrix"]) == length(json_decoded["matrix"])
    end
    
    @testset "BEVE Error Handling" begin
        # Test with invalid BEVE data
        invalid_data = UInt8[0x01, 0x02, 0x03]  # Invalid BEVE format
        
        msg = REPE.Message(
            query = "/test",
            body = invalid_data,
            body_format = UInt16(REPE.BODY_BEVE)
        )
        
        @test_throws Exception parse_body(msg)
    end
    
    @testset "BEVE Complex Data Types" begin
        # Test various Julia data types
        test_cases = [
            Dict("simple" => 42),
            Dict("array" => [1, 2, 3, 4, 5]),
            Dict("nested" => Dict("a" => Dict("b" => Dict("c" => 123)))),
            Dict("mixed_array" => [1, "two", 3.0, true]),
            Dict("unicode" => "Hello 世界 🌍"),
            Dict("large_number" => 9223372036854775807),  # Int64 max
            Dict("small_float" => 1e-10),
            Dict("large_array" => collect(1:1000))
        ]
        
        for (i, test_data) in enumerate(test_cases)
            # Test round-trip
            encoded = REPE.encode_body(test_data, REPE.BODY_BEVE)
            msg = REPE.Message(query="/test$i", body=encoded, body_format=UInt16(REPE.BODY_BEVE))
            decoded = parse_body(msg)
            
            # Basic structure should match
            @test length(keys(decoded)) == length(keys(test_data))
            
            # For simple cases, verify exact content
            if haskey(test_data, "simple")
                @test decoded["simple"] == test_data["simple"]
            end
            if haskey(test_data, "unicode")
                @test decoded["unicode"] == test_data["unicode"]
            end
        end
    end
end