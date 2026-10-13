# Copies llama-server and the libraries and backend plug-ins it loads from SOURCE (a llama.cpp build's bin folder)
# to DESTINATION, keeping symlinks. Run with cmake -P.

file(GLOB_RECURSE files LIST_DIRECTORIES false
    "${SOURCE}/llama-server" "${SOURCE}/llama-server.exe"
    "${SOURCE}/*.so" "${SOURCE}/*.so.*" "${SOURCE}/*.dylib" "${SOURCE}/*.dll")
if (NOT files)
    message(FATAL_ERROR "No llama-server found in ${SOURCE}")
endif()
file(MAKE_DIRECTORY "${DESTINATION}")
file(COPY ${files} DESTINATION "${DESTINATION}" USE_SOURCE_PERMISSIONS)
