#ifndef OPENMW_COMPONENTS_LLM_SERVER_H
#define OPENMW_COMPONENTS_LLM_SERVER_H

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// What the game and the launcher share about the bundled llama-server: where it and the models are, which device
// to run on, and the command line. The [LLM] settings are read here.
namespace LLM
{
    struct Device
    {
        std::string mName; // as llama-server's --device takes it, e.g. CUDA0
        std::string mBackend; // e.g. CUDA
        std::string mDescription; // e.g. NVIDIA GeForce RTX 4090
        int mTotalMiB = 0;
        int mFreeMiB = 0;
    };

    // Parses `llama-server --list-devices` output, which lists GPUs only (the CPU is always available)
    std::vector<Device> parseDevices(std::string_view listDevicesOutput);

    // The device "auto" means: the first CUDA, ROCm, Vulkan or Metal device, in that order, or "cpu" without a GPU.
    // Only one is picked, so the same GPU is never used twice through two backends.
    std::string chooseDevice(const std::vector<Device>& devices);

    // Splits the "extra arguments" setting on whitespace
    std::vector<std::string> splitArguments(std::string_view arguments);

    // llama-server from the [LLM] server path setting, or the bundled one in the "llama" folder
    std::filesystem::path serverPath(const std::filesystem::path& executableDir);

    // Where models are kept and downloaded to: the [LLM] models folder setting; otherwise a "models" folder next to
    // the game if one exists or the game's folder is writable; otherwise "models" in the user data directory.
    std::filesystem::path modelsDir(const std::filesystem::path& executableDir, const std::filesystem::path& userDataDir);

    // .gguf files in a folder, sorted by name
    std::vector<std::filesystem::path> installedModels(const std::filesystem::path& modelsDir);

    // The model from the [LLM] model setting, or the first installed one
    std::optional<std::filesystem::path> findModel(const std::filesystem::path& modelsDir);

    // The number of layers (blocks) in a GGUF model, read from its metadata
    std::optional<int> layerCount(const std::filesystem::path& model);

    // [LLM] gpu layers value for "as many as fit": llama.cpp's --fit picks them, leaving the reserve free
    constexpr int sAutoGpuLayers = -1;

    struct ServerOptions
    {
        std::filesystem::path mModel;
        std::string mDevice; // "cpu" or a device name
        int mContextSize = 8192;
        int mGpuLayers = sAutoGpuLayers;
        int mVramReserveMiB = 3072; // with automatic GPU layers: video memory to leave free for the game
        int mPort = 8080;
        std::string mExtraArguments;
    };

    // ServerOptions from the [LLM] settings, for `model` on `device`
    ServerOptions optionsFromSettings(const std::filesystem::path& model, const std::string& device, int port);

    // The llama-server command line, without the executable
    std::vector<std::string> serverArguments(const ServerOptions& options);
}

#endif
