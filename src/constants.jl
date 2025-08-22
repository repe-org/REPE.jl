const REPE_SPEC = 0x1507
const REPE_VERSION = 0x01
const HEADER_SIZE = 48

@enum ErrorCode::UInt32 begin
    EC_OK = 0
    EC_VERSION_MISMATCH = 1
    EC_INVALID_HEADER = 2
    EC_INVALID_QUERY = 3
    EC_INVALID_BODY = 4
    EC_PARSE_ERROR = 5
    EC_METHOD_NOT_FOUND = 6
    EC_TIMEOUT = 7
    EC_APPLICATION_ERROR_BASE = 4096
end

@enum QueryFormat::UInt16 begin
    QUERY_RAW_BINARY = 0
    QUERY_JSON_POINTER = 1
    QUERY_CUSTOM_BASE = 4096
end

@enum BodyFormat::UInt16 begin
    BODY_RAW_BINARY = 0
    BODY_BEVE = 1
    BODY_JSON = 2
    BODY_UTF8 = 3
    BODY_CUSTOM_BASE = 4096
end

const ERROR_MESSAGES = Dict{ErrorCode, String}(
    EC_OK => "OK",
    EC_VERSION_MISMATCH => "Version mismatch",
    EC_INVALID_HEADER => "Invalid header",
    EC_INVALID_QUERY => "Invalid query",
    EC_INVALID_BODY => "Invalid body",
    EC_PARSE_ERROR => "Parse error",
    EC_METHOD_NOT_FOUND => "Method not found",
    EC_TIMEOUT => "Timeout"
)