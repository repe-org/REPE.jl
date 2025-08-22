#include <glaze/glaze.hpp>
#include <glaze/rpc/repe/repe.hpp>
#include <glaze/beve.hpp>
#include <iostream>
#include <thread>
#include <chrono>
#include <cstring>
#include <vector>
#include <map>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif

// Service with methods to expose via RPC
struct math_service {
   double add(double a, double b) {
      return a + b;
   }
   
   double multiply(double x, double y) {
      return x * y;
   }
   
   double divide(double numerator, double denominator) {
      if (denominator == 0.0) {
         throw std::invalid_argument("Division by zero");
      }
      return numerator / denominator;
   }
   
   std::string echo(const std::string& message) {
      return "Echo: " + message;
   }
   
   std::map<std::string, std::variant<std::string, double, int>> status() {
      return {
         {"status", "online"},
         {"version", "1.0.0"},
         {"uptime", 100.0},
         {"connections", 1}
      };
   }
};

// Simple TCP server using REPE protocol
class repe_tcp_server {
private:
   int server_fd;
   int port;
   bool running;
   math_service service;
   
public:
   repe_tcp_server(int port) : port(port), running(false), server_fd(-1) {}
   
   ~repe_tcp_server() {
      stop();
   }
   
   bool start() {
#ifdef _WIN32
      WSADATA wsaData;
      if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
         std::cerr << "WSAStartup failed\n";
         return false;
      }
#endif
      
      server_fd = socket(AF_INET, SOCK_STREAM, 0);
      if (server_fd < 0) {
         std::cerr << "Failed to create socket\n";
         return false;
      }
      
      int opt = 1;
      if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, 
                     reinterpret_cast<const char*>(&opt), sizeof(opt)) < 0) {
         std::cerr << "Failed to set socket options\n";
         return false;
      }
      
      sockaddr_in address{};
      address.sin_family = AF_INET;
      address.sin_addr.s_addr = INADDR_ANY;
      address.sin_port = htons(port);
      
      if (bind(server_fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
         std::cerr << "Failed to bind to port " << port << "\n";
         close_socket(server_fd);
         return false;
      }
      
      if (listen(server_fd, 5) < 0) {
         std::cerr << "Failed to listen on socket\n";
         close_socket(server_fd);
         return false;
      }
      
      running = true;
      std::cout << "REPE C++ Server (Glaze) listening on port " << port << "\n";
      return true;
   }
   
   void run() {
      while (running) {
         sockaddr_in client_addr{};
         socklen_t client_len = sizeof(client_addr);
         
         int client_fd = accept(server_fd, reinterpret_cast<sockaddr*>(&client_addr), &client_len);
         if (client_fd < 0) {
            if (running) {
               std::cerr << "Failed to accept connection\n";
            }
            continue;
         }
         
         std::cout << "Client connected\n";
         std::thread client_thread([this, client_fd]() {
            handle_client(client_fd);
         });
         client_thread.detach();
      }
   }
   
   void stop() {
      running = false;
      if (server_fd >= 0) {
         close_socket(server_fd);
         server_fd = -1;
      }
#ifdef _WIN32
      WSACleanup();
#endif
   }
   
private:
   void handle_client(int client_fd) {
      while (running) {
         // Create REPE messages for request and response
         glz::repe::message request{};
         glz::repe::message response{};
         
         // Read header first (48 bytes)
         std::vector<uint8_t> header_buffer(sizeof(glz::repe::header));
         ssize_t bytes_read = recv(client_fd, header_buffer.data(), sizeof(glz::repe::header), MSG_WAITALL);
         
         if (bytes_read <= 0) {
            break;
         }
         
         if (bytes_read != sizeof(glz::repe::header)) {
            std::cerr << "Invalid header size: " << bytes_read << "\n";
            break;
         }
         
         // Copy header data
         std::memcpy(&request.header, header_buffer.data(), sizeof(glz::repe::header));
         
         // Validate REPE spec
         if (request.header.spec != 0x1507) {
            std::cerr << "Invalid REPE spec: " << std::hex << request.header.spec << std::dec << "\n";
            break;
         }
         
         // Check version
         if (request.header.version != 1) {
            std::cerr << "Unsupported REPE version: " << static_cast<int>(request.header.version) << "\n";
            response.header = request.header;
            response.header.ec = glz::error_code::version_mismatch;
            response.body = "Version mismatch";
            send_response(client_fd, response);
            break;
         }
         
         // Read query if present
         if (request.header.query_length > 0) {
            request.query.resize(request.header.query_length);
            bytes_read = recv(client_fd, request.query.data(), request.header.query_length, MSG_WAITALL);
            if (bytes_read != static_cast<ssize_t>(request.header.query_length)) {
               std::cerr << "Failed to read query\n";
               break;
            }
         }
         
         // Read body if present
         if (request.header.body_length > 0) {
            request.body.resize(request.header.body_length);
            bytes_read = recv(client_fd, request.body.data(), request.header.body_length, MSG_WAITALL);
            if (bytes_read != static_cast<ssize_t>(request.header.body_length)) {
               std::cerr << "Failed to read body\n";
               break;
            }
         }
         
         std::string format_name = (request.header.body_format == 1) ? "BEVE" : 
                                   (request.header.body_format == 2) ? "JSON" : 
                                   (request.header.body_format == 3) ? "UTF8" : "BINARY";
         std::cout << "Request ID " << request.header.id << ", Query: " << request.query 
                   << ", Format: " << format_name << " (" << request.header.body_format << ")\n";
         
         // Process the request
         process_request(request, response);
         
         // Don't send response for notify requests
         if (request.header.notify) {
            std::cout << "Notification received, no response sent\n";
            continue;
         }
         
         // Send response
         send_response(client_fd, response);
         std::cout << "Response sent for request ID: " << request.header.id << "\n";
      }
      
      close_socket(client_fd);
      std::cout << "Client disconnected\n";
   }
   
   // Helper function to decode parameters based on body format
   template<typename T>
   std::optional<T> decode_params(const glz::repe::message& request) {
      if (request.header.body_format == 1) { // BEVE
         auto result = glz::read_beve<T>(request.body);
         if (result) {
            return result.value();
         }
      } else if (request.header.body_format == 2) { // JSON
         auto result = glz::read_json<T>(request.body);
         if (result) {
            return result.value();
         }
      }
      return std::nullopt;
   }
   
   // Helper function to encode response based on preferred format
   template<typename T>
   void encode_response(const T& data, glz::repe::message& response, uint16_t format = 2) {
      if (format == 1) { // BEVE
         glz::write_beve(data, response.body);
         response.header.body_format = 1;
      } else { // JSON (default)
         glz::write_json(data, response.body);
         response.header.body_format = 2;
      }
   }

   void process_request(const glz::repe::message& request, glz::repe::message& response) {
      // Copy request ID and query
      response.header.id = request.header.id;
      response.query = request.query;
      response.header.spec = 0x1507;
      response.header.version = 1;
      
      // Parse method from query (remove leading slash if present)
      std::string method = request.query;
      if (!method.empty() && method[0] == '/') {
         method = method.substr(1);
      }
      
      // Default to same format as request for response
      uint16_t response_format = request.header.body_format;
      
      // Process based on method
      if (method == "add") {
         auto params = decode_params<std::map<std::string, double>>(request);
         if (params) {
            double result = service.add(params.value()["a"], params.value()["b"]);
            auto res_map = std::map<std::string, double>{{"result", result}};
            encode_response(res_map, response, response_format);
         } else {
            response.header.ec = glz::error_code::parse_error;
            response.body = "Invalid parameters for add";
            response.header.body_format = 3; // UTF-8
         }
      }
      else if (method == "multiply") {
         auto params = decode_params<std::map<std::string, double>>(request);
         if (params) {
            double result = service.multiply(params.value()["x"], params.value()["y"]);
            auto res_map = std::map<std::string, double>{{"result", result}};
            encode_response(res_map, response, response_format);
         } else {
            response.header.ec = glz::error_code::parse_error;
            response.body = "Invalid parameters for multiply";
            response.header.body_format = 3; // UTF-8
         }
      }
      else if (method == "divide") {
         auto params = decode_params<std::map<std::string, double>>(request);
         if (params) {
            try {
               double result = service.divide(params.value()["numerator"], params.value()["denominator"]);
               auto res_map = std::map<std::string, double>{{"result", result}};
               encode_response(res_map, response, response_format);
            } catch (const std::invalid_argument& e) {
               response.header.ec = glz::error_code::invalid_body;
               response.body = e.what();
               response.header.body_format = 3; // UTF-8
            }
         } else {
            response.header.ec = glz::error_code::parse_error;
            response.body = "Invalid parameters for divide";
            response.header.body_format = 3; // UTF-8
         }
      }
      else if (method == "echo") {
         auto params = decode_params<std::map<std::string, std::string>>(request);
         if (params) {
            std::string result = service.echo(params.value()["message"]);
            auto res_map = std::map<std::string, std::string>{{"result", result}};
            encode_response(res_map, response, response_format);
         } else {
            response.header.ec = glz::error_code::parse_error;
            response.body = "Invalid parameters for echo";
            response.header.body_format = 3; // UTF-8
         }
      }
      else if (method == "status") {
         auto result = service.status();
         encode_response(result, response, response_format);
      }
      else {
         response.header.ec = glz::error_code::method_not_found;
         response.body = "Method not found: " + method;
         response.header.body_format = 3; // UTF-8
      }
      
      // Update header lengths
      response.header.query_length = response.query.size();
      response.header.body_length = response.body.size();
      response.header.length = sizeof(glz::repe::header) + response.header.query_length + response.header.body_length;
   }
   
   void send_response(int client_fd, const glz::repe::message& response) {
      // Create buffer for entire response
      std::vector<uint8_t> buffer(response.header.length);
      
      // Copy header
      std::memcpy(buffer.data(), &response.header, sizeof(glz::repe::header));
      
      // Copy query
      if (!response.query.empty()) {
         std::memcpy(buffer.data() + sizeof(glz::repe::header), 
                     response.query.data(), response.query.size());
      }
      
      // Copy body
      if (!response.body.empty()) {
         std::memcpy(buffer.data() + sizeof(glz::repe::header) + response.query.size(),
                     response.body.data(), response.body.size());
      }
      
      // Send entire response
      send(client_fd, buffer.data(), buffer.size(), 0);
   }
   
   void close_socket(int fd) {
#ifdef _WIN32
      closesocket(fd);
#else
      close(fd);
#endif
   }
};

int main(int argc, char* argv[]) {
   int port = 8081;
   if (argc > 1) {
      port = std::atoi(argv[1]);
   }
   
   repe_tcp_server server(port);
   
   if (!server.start()) {
      std::cerr << "Failed to start server\n";
      return 1;
   }
   
   std::cout << "Server running. Press Ctrl+C to stop.\n";
   server.run();
   
   return 0;
}