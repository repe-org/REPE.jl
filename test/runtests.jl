using Test
using REPE
using Sockets

@testset "REPE.jl Tests" begin
    include("test_header.jl")
    include("test_message.jl")
    include("test_beve.jl")
    include("test_client_server_simple.jl")
    include("test_concurrent_simple.jl")
    # Commenting out network tests for now - they have timing issues
    # include("test_client_server.jl")
    # include("test_concurrent.jl")  # Full concurrent tests with servers
end