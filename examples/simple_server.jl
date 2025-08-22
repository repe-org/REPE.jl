using REPE

server = REPEServer("localhost", 8080)

register_handler(server, "/api/add", function(params, request)
    a = get(params, "a", 0)
    b = get(params, "b", 0)
    return Dict("result" => a + b)
end)

register_handler(server, "/api/multiply", function(params, request)
    x = get(params, "x", 0)
    y = get(params, "y", 0)
    return Dict("result" => x * y)
end)

register_handler(server, "/api/get_data", function(params, request)
    return Dict(
        "timestamp" => time(),
        "version" => "1.0.0",
        "data" => [1, 2, 3, 4, 5]
    )
end)

register_handler(server, "/api/log", function(params, request)
    println("Log: ", params)
    return Dict("status" => "logged")
end)

add_middleware(server, function(request)
    println("Request: ", parse_query(request))
    return nothing
end)

println("Starting REPE server on localhost:8080...")
start_server(server)