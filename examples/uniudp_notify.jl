# UniUDP REPE Example
#
# This example demonstrates one-way RPC over UDP using REPE + UniUDP.
# Run the receiver first, then the sender in separate terminals.
#
# Receiver: julia examples/uniudp_notify.jl receiver
# Sender:   julia examples/uniudp_notify.jl sender

using REPE
using UniUDP
using Sockets

const PORT = 5555

function run_receiver()
    println("Starting UniUDP REPE receiver on port $PORT...")

    # Create server with a response callback for non-notify requests
    server = UniUDPServer(PORT;
        inactivity_timeout = 1.0,
        overall_timeout = 60.0,
        response_callback = (method, result, msg) -> begin
            println("[RESULT] $method returned: $result")
        end
    )

    # Register handlers for notifications (fire-and-forget)
    register(server, "/sensor/temperature") do params, msg
        println("[TEMP] $(params["location"]): $(params["value"])$(params["unit"])")
    end

    register(server, "/sensor/humidity") do params, msg
        println("[HUMIDITY] $(params["location"]): $(params["value"])%")
    end

    register(server, "/event/alert") do params, msg
        println("[ALERT] $(params["level"]): $(params["message"])")
    end

    # Register handlers for requests (compute and callback with result)
    register(server, "/compute/factorial") do params, msg
        n = params["n"]
        result = factorial(big(n))
        return result  # Goes to response_callback
    end

    register(server, "/compute/fibonacci") do params, msg
        n = params["n"]
        a, b = big(0), big(1)
        for _ in 1:n
            a, b = b, a + b
        end
        return a  # Goes to response_callback
    end

    register(server, "/shutdown") do params, msg
        println("[SHUTDOWN] Received shutdown signal")
        stop(server)
    end

    println("Handlers registered. Waiting for messages...")
    println("Press Ctrl+C to stop.\n")

    listen(server)  # Blocks until stop() is called

    close(server)
    println("Receiver stopped.")
end

function run_sender()
    println("Creating UniUDP REPE sender targeting localhost:$PORT...")

    client = UniUDPClient(
        ip"127.0.0.1", PORT;
        redundancy = 2,
        chunk_size = 1024,
        fec_group_size = 4
    )

    println("Sending sensor notifications...\n")

    # Simulate sensor readings (notifications - no response expected)
    locations = ["kitchen", "bedroom", "garage", "outdoor"]

    for i in 1:3
        for loc in locations
            temp = 18.0 + rand() * 12.0
            send_notify(client, "/sensor/temperature", Dict(
                "location" => loc,
                "value" => round(temp, digits=1),
                "unit" => "C",
                "timestamp" => time()
            ))

            humidity = 40.0 + rand() * 40.0
            send_notify(client, "/sensor/humidity", Dict(
                "location" => loc,
                "value" => round(humidity, digits=1),
                "timestamp" => time()
            ))
        end

        println("Sent batch $i of sensor readings")
        sleep(0.3)
    end

    # Send an alert notification
    send_notify(client, "/event/alert", Dict(
        "level" => "WARNING",
        "message" => "High temperature detected in garage",
        "source" => "temperature_monitor"
    ))

    println("\nSending compute requests (results shown on receiver)...\n")

    # Send computation requests (server computes, result goes to callback)
    send_request(client, "/compute/factorial", Dict("n" => 20))
    println("Sent factorial(20) request")

    send_request(client, "/compute/fibonacci", Dict("n" => 50))
    println("Sent fibonacci(50) request")

    sleep(0.5)
    println("\nAll messages sent.")

    # Optionally send shutdown signal
    print("Send shutdown signal to receiver? [y/N]: ")
    response = readline()
    if lowercase(strip(response)) == "y"
        send_notify(client, "/shutdown", nothing)
        println("Shutdown signal sent.")
    end

    close(client)
end

# Main entry point
if length(ARGS) < 1
    println("Usage: julia uniudp_notify.jl [receiver|sender]")
    exit(1)
end

mode = lowercase(ARGS[1])

if mode == "receiver"
    run_receiver()
elseif mode == "sender"
    run_sender()
else
    println("Unknown mode: $mode")
    println("Use 'receiver' or 'sender'")
    exit(1)
end
