module REPE

using Sockets
import BEVE as BEVEModule

module JSONInternal
using JSON
end

const JSONLib = JSONInternal.JSON

export Header, Message, Client, Server
export ErrorCode, QueryFormat, BodyFormat
export send_request, send_request_async, send_notify
export REPEError, ConnectionError, TimeoutError, ValidationError
export batch, await_batch
export connect, disconnect, listen, stop, isconnected, wait_for_server
export serialize_message, deserialize_message
export parse_query, parse_body, encode_body
export set_nodelay!
# Registry exports
export Registry, serve, register!
export parse_json_pointer, resolve_json_pointer, set_json_pointer!

include("constants.jl")
include("header.jl")
include("message.jl")
include("client.jl")
include("server.jl")
include("registry.jl")
include("errors.jl")

end
