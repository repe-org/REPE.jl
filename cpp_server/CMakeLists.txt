cmake_minimum_required(VERSION 3.15)
project(repe_server)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# Fetch Glaze
FetchContent_Declare(
  glaze
  GIT_REPOSITORY https://github.com/stephenberry/glaze.git
  GIT_TAG main
  GIT_SHALLOW TRUE
)

FetchContent_MakeAvailable(glaze)

# Create server executable
add_executable(repe_server repe_server.cpp)
target_link_libraries(repe_server PRIVATE glaze::glaze)

# Set build flags
if(MSVC)
  target_compile_options(repe_server PRIVATE /W4)
else()
  target_compile_options(repe_server PRIVATE -Wall -Wextra -Wpedantic)
endif()