using REPE

client = REPE.Client("localhost", 8080)

connect(client)

try
    result = send_request(client, "/api/add", Dict("a" => 10, "b" => 20))
    println("Add result: ", result)
    
    result = send_request(client, "/api/multiply", Dict("x" => 5, "y" => 7))
    println("Multiply result: ", result)
    
    data = send_request(client, "/api/get_data", nothing)
    println("Data: ", data)
    
    send_notify(client, "/api/log", "Client activity logged")
    
finally
    disconnect(client)
end