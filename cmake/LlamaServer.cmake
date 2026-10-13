# Builds llama-server from llama.cpp and puts it in a "llama" folder next to the openmw executable, where the game
# starts it from (apps/openmw/mwlua/llmserver.cpp). GPU backends are built as plug-ins (GGML_BACKEND_DL), so one
# build carries every backend the build machine can compile, and the player picks the device at run time with the
# [LLM] device setting. llama.cpp is configured as a separate project so its options can't clash with OpenMW's.

include(ExternalProject)
include(CheckLanguage)

set(OPENMW_LLAMA_CPP_VERSION b11559)
set(OPENMW_LLAMA_SOURCE_DIR "" CACHE PATH
    "llama.cpp checkout to build llama-server from (empty: download llama.cpp ${OPENMW_LLAMA_CPP_VERSION})")
set(OPENMW_LLAMA_CUDA AUTO CACHE STRING "Build llama-server's CUDA backend (AUTO: if a CUDA compiler is found)")
set_property(CACHE OPENMW_LLAMA_CUDA PROPERTY STRINGS AUTO ON OFF)
set(OPENMW_LLAMA_VULKAN AUTO CACHE STRING "Build llama-server's Vulkan backend (AUTO: if Vulkan and glslc are found)")
set_property(CACHE OPENMW_LLAMA_VULKAN PROPERTY STRINGS AUTO ON OFF)
set(OPENMW_LLAMA_CUDA_ARCHITECTURES native CACHE STRING
    "CUDA architectures to build for (native: the build machine's GPU; use a list like 75;86;89 for releases)")

if (OPENMW_LLAMA_CUDA STREQUAL "AUTO")
    check_language(CUDA)
    if (CMAKE_CUDA_COMPILER)
        set(llama_cuda ON)
    else()
        set(llama_cuda OFF)
    endif()
elseif (OPENMW_LLAMA_CUDA)
    set(llama_cuda ON)
else()
    set(llama_cuda OFF)
endif()

if (OPENMW_LLAMA_VULKAN STREQUAL "AUTO")
    find_package(Vulkan QUIET)
    find_program(OPENMW_GLSLC glslc HINTS "$ENV{VULKAN_SDK}/bin")
    if (Vulkan_FOUND AND OPENMW_GLSLC)
        set(llama_vulkan ON)
    else()
        set(llama_vulkan OFF)
    endif()
elseif (OPENMW_LLAMA_VULKAN)
    set(llama_vulkan ON)
else()
    set(llama_vulkan OFF)
endif()

message(STATUS "Bundled llama-server ${OPENMW_LLAMA_CPP_VERSION}: CPU backend, CUDA ${llama_cuda}, Vulkan ${llama_vulkan}")

set(llama_args
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DGGML_BACKEND_DL=ON
    -DGGML_NATIVE=OFF
    -DGGML_CUDA=${llama_cuda}
    -DGGML_VULKAN=${llama_vulkan}
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_UI=OFF
    -DLLAMA_USE_PREBUILT_UI=OFF
    -DLLAMA_OPENSSL=OFF
    # Libraries find each other next to llama-server, wherever the folder is copied to
    -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON
)
# CPU variants for every instruction set, chosen at run time (supported on x86-64 and ARM64)
if (CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64|aarch64|arm64|ARM64)$")
    list(APPEND llama_args -DGGML_CPU_ALL_VARIANTS=ON)
endif()
if (llama_cuda)
    list(APPEND llama_args "-DCMAKE_CUDA_ARCHITECTURES=${OPENMW_LLAMA_CUDA_ARCHITECTURES}")
    if (CMAKE_CUDA_COMPILER)
        list(APPEND llama_args "-DCMAKE_CUDA_COMPILER=${CMAKE_CUDA_COMPILER}")
    endif()
endif()
if (llama_vulkan AND OPENMW_GLSLC)
    list(APPEND llama_args "-DVulkan_GLSLC_EXECUTABLE=${OPENMW_GLSLC}")
endif()

if (OPENMW_LLAMA_SOURCE_DIR)
    set(llama_source SOURCE_DIR "${OPENMW_LLAMA_SOURCE_DIR}")
    # Rebuild when the checkout changes
    set(llama_build_always ON)
else()
    set(llama_build_always OFF)
    set(llama_source
        URL https://github.com/ggml-org/llama.cpp/archive/refs/tags/${OPENMW_LLAMA_CPP_VERSION}.tar.gz
        URL_HASH SHA512=ca212e45679dfe266558338c0a0d5f40b7b570477d5cea74dee84935c5d2790bccad0c2e6cc7cb3f819a3dd16f6181dc923c85ea338b7fdf17ef96b767e9be4a
        DOWNLOAD_EXTRACT_TIMESTAMP ON
    )
endif()

ExternalProject_Add(llama_server
    ${llama_source}
    PREFIX "${CMAKE_BINARY_DIR}/extern/llama.cpp"
    CMAKE_ARGS ${llama_args}
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config Release --target llama-server --parallel
    INSTALL_COMMAND ${CMAKE_COMMAND} -DSOURCE=<BINARY_DIR>/bin "-DDESTINATION=$<TARGET_FILE_DIR:openmw>/llama"
        -P "${CMAKE_CURRENT_LIST_DIR}/CopyLlamaServer.cmake"
    BUILD_ALWAYS ${llama_build_always}
    USES_TERMINAL_BUILD ON
)
# Part of the default build. Not a dependency of openmw: the copy step needs openmw's output folder.

install(DIRECTORY "$<TARGET_FILE_DIR:openmw>/llama" DESTINATION "${CMAKE_INSTALL_BINDIR}" USE_SOURCE_PERMISSIONS)
