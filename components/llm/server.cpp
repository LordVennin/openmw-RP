#include "server.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <functional>
#include <stdexcept>
#include <regex>
#include <sstream>

#include <components/files/conversion.hpp>
#include <components/settings/values.hpp>

namespace LLM
{
    namespace
    {
        bool isWritable(const std::filesystem::path& dir)
        {
            const std::filesystem::path probe = dir / ".openmw-write-test";
            {
                std::ofstream file(probe);
                if (!file)
                    return false;
            }
            std::error_code ec;
            std::filesystem::remove(probe, ec);
            return true;
        }

#ifdef _WIN32
        constexpr const char* sServerExecutable = "llama-server.exe";
#else
        constexpr const char* sServerExecutable = "llama-server";
#endif
    }

    std::vector<Device> parseDevices(std::string_view listDevicesOutput)
    {
        // Lines look like "  CUDA0: NVIDIA GeForce RTX 4090 (24076 MiB, 23000 MiB free)"
        static const std::regex deviceLine(R"(^\s+([A-Za-z]+)(\d+):\s+(.*?)\s*\((\d+) MiB, (\d+) MiB free\))");
        std::vector<Device> devices;
        std::istringstream lines{ std::string(listDevicesOutput) };
        std::string line;
        while (std::getline(lines, line))
        {
            std::smatch match;
            if (std::regex_search(line, match, deviceLine))
                devices.push_back(Device{ match[1].str() + match[2].str(), match[1].str(), match[3].str(),
                    std::stoi(match[4].str()), std::stoi(match[5].str()) });
        }
        return devices;
    }

    std::string chooseDevice(const std::vector<Device>& devices)
    {
        static constexpr std::array preferred{ "CUDA", "ROCm", "Vulkan", "Metal" };
        for (std::string_view backend : preferred)
            for (const Device& device : devices)
                if (device.mBackend == backend)
                    return device.mName;
        return "cpu";
    }

    std::vector<std::string> splitArguments(std::string_view arguments)
    {
        std::vector<std::string> result;
        std::istringstream stream{ std::string(arguments) };
        std::string argument;
        while (stream >> argument)
            result.push_back(argument);
        return result;
    }

    std::filesystem::path serverPath(const std::filesystem::path& executableDir)
    {
        const std::string& setting = Settings::llm().mServerPath;
        if (!setting.empty())
            return Files::pathFromUnicodeString(setting);
        return executableDir / "llama" / sServerExecutable;
    }

    std::filesystem::path modelsDir(const std::filesystem::path& executableDir, const std::filesystem::path& userDataDir)
    {
        const std::string& setting = Settings::llm().mModelsFolder;
        if (!setting.empty())
            return Files::pathFromUnicodeString(setting);
        std::error_code ec;
        const std::filesystem::path besideGame = executableDir / "models";
        if (std::filesystem::is_directory(besideGame, ec))
            return besideGame;
        if (isWritable(executableDir))
            return besideGame;
        return userDataDir / "models";
    }

    std::vector<std::filesystem::path> installedModels(const std::filesystem::path& modelsDir)
    {
        std::error_code ec;
        std::vector<std::filesystem::path> models;
        for (const auto& entry : std::filesystem::directory_iterator(modelsDir, ec))
        {
            std::string extension = Files::pathToUnicodeString(entry.path().extension());
            std::transform(extension.begin(), extension.end(), extension.begin(),
                [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            if (extension == ".gguf" && entry.is_regular_file(ec))
                models.push_back(entry.path());
        }
        std::sort(models.begin(), models.end());
        return models;
    }

    std::optional<std::filesystem::path> findModel(const std::filesystem::path& modelsDir)
    {
        const std::string& setting = Settings::llm().mModel;
        if (!setting.empty())
            return Files::pathFromUnicodeString(setting);
        std::vector<std::filesystem::path> models = installedModels(modelsDir);
        if (models.empty())
            return std::nullopt;
        return models.front();
    }

    std::optional<int> layerCount(const std::filesystem::path& model)
    {
        // GGUF: magic, version, tensor count, metadata count, then metadata as (key, type, value). Layer counts are
        // stored as "<architecture>.block_count", which comes before the large tokenizer arrays.
        std::ifstream file(model, std::ios::binary);
        auto readU32 = [&] { std::uint32_t v = 0; file.read(reinterpret_cast<char*>(&v), sizeof(v)); return v; };
        auto readU64 = [&] { std::uint64_t v = 0; file.read(reinterpret_cast<char*>(&v), sizeof(v)); return v; };
        auto readString = [&] {
            const std::uint64_t length = readU64();
            if (length > (1 << 20))
                throw std::runtime_error("bad string");
            std::string s(length, '\0');
            file.read(s.data(), static_cast<std::streamsize>(length));
            return s;
        };
        // Sizes of the fixed-size value types, by GGUF type id (0-12); 0 for string (8) and array (9)
        static constexpr std::array<int, 13> sizes{ 1, 1, 2, 2, 4, 4, 4, 1, 0, 0, 8, 8, 8 };
        std::function<void(std::uint32_t)> skip = [&](std::uint32_t type) {
            if (type >= sizes.size())
                throw std::runtime_error("bad type");
            if (type == 8)
                readString();
            else if (type == 9)
            {
                const std::uint32_t itemType = readU32();
                const std::uint64_t count = readU64();
                if (itemType != 8 && itemType != 9 && itemType < sizes.size())
                    file.seekg(static_cast<std::streamoff>(count * sizes[itemType]), std::ios::cur);
                else
                    for (std::uint64_t i = 0; i < count && file; ++i)
                        skip(itemType);
            }
            else
                file.seekg(sizes[type], std::ios::cur);
        };
        try
        {
            if (readU32() != 0x46554747) // "GGUF"
                return std::nullopt;
            readU32(); // version
            readU64(); // tensor count
            const std::uint64_t metadataCount = readU64();
            for (std::uint64_t i = 0; i < metadataCount && file; ++i)
            {
                const std::string key = readString();
                const std::uint32_t type = readU32();
                const std::string_view suffix = ".block_count";
                if (key.size() > suffix.size() && key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0
                    && (type == 4 || type == 5))
                    return static_cast<int>(readU32());
                skip(type);
            }
        }
        catch (const std::exception&)
        {
        }
        return std::nullopt;
    }

    ServerOptions optionsFromSettings(const std::filesystem::path& model, const std::string& device, int port)
    {
        return ServerOptions{ model, device, Settings::llm().mContextSize, Settings::llm().mGpuLayers,
            Settings::llm().mVramReserveMiB, port, Settings::llm().mExtraArguments };
    }

    std::vector<std::string> serverArguments(const ServerOptions& options)
    {
        std::vector<std::string> arguments{ "--model", Files::pathToUnicodeString(options.mModel), "--ctx-size",
            std::to_string(options.mContextSize), "--parallel", "1", "--host", "127.0.0.1", "--port",
            std::to_string(options.mPort) };
        if (options.mDevice == "cpu")
            arguments.insert(arguments.end(), { "--device", "none", "--n-gpu-layers", "0" });
        else if (options.mGpuLayers == sAutoGpuLayers)
            // llama.cpp puts as many layers on the GPU as fit, leaving the reserve free, and the rest on the CPU
            arguments.insert(arguments.end(),
                { "--device", options.mDevice, "--fit", "on", "--fit-target", std::to_string(options.mVramReserveMiB) });
        else
            arguments.insert(arguments.end(),
                { "--device", options.mDevice, "--n-gpu-layers", std::to_string(options.mGpuLayers), "--fit", "off" });
        for (std::string& argument : splitArguments(options.mExtraArguments))
            arguments.push_back(std::move(argument));
        return arguments;
    }
}
