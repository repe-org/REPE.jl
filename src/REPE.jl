module REPE

using Sockets
using JSON3
using StructTypes
import BEVE as BEVEModule

export Header, Message, Client, Server
export ErrorCode, QueryFormat, BodyFormat
export send_request, send_request_async, send_notify
export REPEError, ConnectionError, TimeoutError, ValidationError
export batch, await_batch
export connect, disconnect, listen, isconnected
export serialize_message, deserialize_message
export parse_query, parse_body, encode_body

include("constants.jl")
include("header.jl")
include("message.jl")
include("client.jl")
include("server.jl")
include("errors.jl")

end