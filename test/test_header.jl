@testset "Header Tests" begin
    @testset "Header Creation" begin
        header = REPE.REPEHeader()
        @test header.spec == REPE.REPE_SPEC
        @test header.version == REPE.REPE_VERSION
        @test header.notify == 0
        @test header.reserved == 0
        @test header.id == 0
        @test header.query_length == 0
        @test header.body_length == 0
        @test header.ec == UInt32(REPE.EC_OK)
    end
    
    @testset "Header Serialization" begin
        header = REPE.REPEHeader(
            length = 100,
            id = 42,
            query_length = 10,
            body_length = 42
        )
        
        bytes = REPE.serialize_header(header)
        @test length(bytes) == REPE.HEADER_SIZE
        
        header2 = REPE.deserialize_header(bytes)
        @test header2.spec == header.spec
        @test header2.version == header.version
        @test header2.id == header.id
        @test header2.query_length == header.query_length
        @test header2.body_length == header.body_length
    end
    
    @testset "Header Validation" begin
        header = REPE.REPEHeader(
            length = REPE.HEADER_SIZE + 10 + 20,
            query_length = 10,
            body_length = 20
        )
        @test REPE.validate_header(header) == true
        
        bad_header = REPE.REPEHeader(
            length = 100,
            spec = 0x0000,
            query_length = 10,
            body_length = 20
        )
        @test REPE.validate_header(bad_header) == false
        
        bad_version = REPE.REPEHeader(
            length = REPE.HEADER_SIZE,
            version = 0xFF
        )
        @test REPE.validate_header(bad_version) == false
    end
    
    @testset "Header Endianness" begin
        header = REPE.REPEHeader(
            length = 0x0102030405060708,
            id = 0x090A0B0C0D0E0F10
        )
        
        bytes = REPE.serialize_header(header)
        
        @test bytes[1:8] == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        
        @test bytes[17:24] == [0x10, 0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09]
    end
end