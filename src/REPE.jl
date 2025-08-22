module REPE

using Sockets
using JSON3
using StructTypes
using BEVE

export REPEHeader, REPEMessage, REPEClient, REPEServer
export ErrorCode, QueryFormat, BodyFormat
export send_request, send_request_async, send_notify, parse_message, build_message
export batch, await_batch
export connect, disconnect, listen

include("constants.jl")
include("header.jl")
include("message.jl")
include("client.jl")
include("server.jl")
include("errors.jl")

end