#include "llmserver.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <utility>

#include <httplib.h>

#include <components/debug/debuglog.hpp>
#include <components/files/conversion.hpp>
#include <components/settings/values.hpp>

#ifdef _WIN32
#include <windows.h>
#else
#include <arpa/inet.h>
#include <csignal>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#endif

namespace MWLua
{
    namespace
    {
        constexpr const char* sHost = "127.0.0.1";
        constexpr int sPortsToTry = 100;
        constexpr auto sPollInterval = std::chrono::milliseconds(250);
        constexpr auto sWatchInterval = std::chrono::seconds(1);
        constexpr auto sLoadTimeout = std::chrono::minutes(10);
        constexpr auto sListDevicesTimeout = std::chrono::seconds(30);
        constexpr auto sStopTimeout = std::chrono::seconds(5);

#ifdef _WIN32
        constexpr const char* sServerExecutable = "llama-server.exe";
#else
        constexpr const char* sServerExecutable = "llama-server";
#endif

        enum class Health
        {
            None, // nothing answers
            Loading, // a llama-server is loading its model
            Ready,
        };

        Health checkHealth(int port)
        {
            httplib::Client client(sHost, port);
            client.set_connection_timeout(0, 500'000);
            client.set_read_timeout(2, 0);
            httplib::Result response = client.Get("/health");
            if (!response)
                return Health::None;
            if (response->status == 200)
                return Health::Ready;
            if (response->status == 503)
                return Health::Loading;
            return Health::None;
        }

        // The context size the server runs with, from /props
        std::optional<int> fetchContextSize(int port)
        {
            httplib::Client client(sHost, port);
            client.set_connection_timeout(0, 500'000);
            client.set_read_timeout(2, 0);
            httplib::Result response = client.Get("/props");
            if (!response || response->status != 200)
                return std::nullopt;
            static const std::regex nCtx(R"("n_ctx"\s*:\s*(\d+))");
            std::smatch match;
            if (!std::regex_search(response->body, match, nCtx))
                return std::nullopt;
            return std::stoi(match[1].str());
        }

        bool isPortFree(int port)
        {
#ifdef _WIN32
            SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (sock == INVALID_SOCKET)
                return false;
#else
            int sock = socket(AF_INET, SOCK_STREAM, 0);
            if (sock < 0)
                return false;
            // As llama-server's own listening socket does, so ports in TIME_WAIT count as free
            int reuse = 1;
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
#endif
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_port = htons(static_cast<unsigned short>(port));
            inet_pton(AF_INET, sHost, &address.sin_addr);
            const bool free = bind(sock, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
#ifdef _WIN32
            closesocket(sock);
#else
            close(sock);
#endif
            return free;
        }

        std::optional<int> findFreePort(int first)
        {
            for (int port = first; port < first + sPortsToTry && port <= 65535; ++port)
                if (isPortFree(port))
                    return port;
            return std::nullopt;
        }

        std::optional<std::filesystem::path> findModel(const std::filesystem::path& userDataDir)
        {
            const std::string& setting = Settings::llm().mModel;
            if (!setting.empty())
                return Files::pathFromUnicodeString(setting);
            const std::filesystem::path modelsDir = userDataDir / "models";
            std::error_code ec;
            std::vector<std::filesystem::path> models;
            for (const auto& entry : std::filesystem::directory_iterator(modelsDir, ec))
            {
                std::string extension = Files::pathToUnicodeString(entry.path().extension());
                std::transform(extension.begin(), extension.end(), extension.begin(),
                    [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                if (entry.is_regular_file(ec) && extension == ".gguf")
                    models.push_back(entry.path());
            }
            if (models.empty())
                return std::nullopt;
            std::sort(models.begin(), models.end());
            return models.front();
        }

        std::filesystem::path findServer(const std::filesystem::path& executableDir)
        {
            const std::string& setting = Settings::llm().mServerPath;
            if (!setting.empty())
                return Files::pathFromUnicodeString(setting);
            return executableDir / "llama" / sServerExecutable;
        }

        std::string readFile(const std::filesystem::path& path)
        {
            std::ifstream stream(path, std::ios::binary);
            std::ostringstream content;
            content << stream.rdbuf();
            return content.str();
        }
    }

    // A child process with its output redirected to a file. It is killed when this object is destroyed,
    // and, through the OS, when the game crashes.
    class ChildProcess
    {
    public:
        ChildProcess(const std::filesystem::path& executable, const std::vector<std::string>& arguments,
            const std::filesystem::path& outputFile);
        ~ChildProcess();

        ChildProcess(const ChildProcess&) = delete;
        ChildProcess& operator=(const ChildProcess&) = delete;

        // Returns the exit code if the process has exited
        std::optional<int> exitCode();

        // Asks the process to stop, and kills it if it hasn't after `timeout`
        void stop(std::chrono::milliseconds timeout);

    private:
#ifdef _WIN32
        HANDLE mProcess = nullptr;
        HANDLE mJob = nullptr;
#else
        pid_t mPid = -1;
#endif
        std::optional<int> mExitCode;
    };

#ifdef _WIN32
    namespace
    {
        // Quotes an argument for CommandLineToArgvW
        std::wstring quoteArgument(const std::wstring& argument)
        {
            std::wstring quoted = L"\"";
            std::size_t backslashes = 0;
            for (wchar_t c : argument)
            {
                if (c == L'\\')
                {
                    ++backslashes;
                    continue;
                }
                if (c == L'"')
                    quoted.append(backslashes * 2 + 1, L'\\');
                else
                    quoted.append(backslashes, L'\\');
                backslashes = 0;
                quoted += c;
            }
            quoted.append(backslashes * 2, L'\\');
            quoted += L'"';
            return quoted;
        }

        std::wstring toWide(const std::string& utf8)
        {
            if (utf8.empty())
                return {};
            const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
            std::wstring wide(size, L'\0');
            MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(), size);
            return wide;
        }
    }

    ChildProcess::ChildProcess(const std::filesystem::path& executable, const std::vector<std::string>& arguments,
        const std::filesystem::path& outputFile)
    {
        std::wstring commandLine = quoteArgument(executable.wstring());
        for (const std::string& argument : arguments)
            commandLine += L" " + quoteArgument(toWide(argument));

        SECURITY_ATTRIBUTES inherit{ sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE };
        HANDLE output = CreateFileW(outputFile.wstring().c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            &inherit, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (output == INVALID_HANDLE_VALUE)
            throw std::runtime_error("cannot write " + Files::pathToUnicodeString(outputFile));

        // Closing the job's last handle (also when the game crashes) kills the process
        mJob = CreateJobObjectW(nullptr, nullptr);
        if (mJob != nullptr)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(mJob, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
        }

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = nullptr;
        startup.hStdOutput = output;
        startup.hStdError = output;
        PROCESS_INFORMATION info{};
        const BOOL created = CreateProcessW(executable.wstring().c_str(), commandLine.data(), nullptr, nullptr, TRUE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &info);
        const DWORD error = GetLastError();
        CloseHandle(output);
        if (!created)
        {
            if (mJob != nullptr)
                CloseHandle(mJob);
            throw std::runtime_error("cannot start " + Files::pathToUnicodeString(executable) + " (error "
                + std::to_string(error) + ")");
        }
        if (mJob != nullptr)
            AssignProcessToJobObject(mJob, info.hProcess);
        ResumeThread(info.hThread);
        CloseHandle(info.hThread);
        mProcess = info.hProcess;
    }

    ChildProcess::~ChildProcess()
    {
        stop(std::chrono::milliseconds(0));
        CloseHandle(mProcess);
        if (mJob != nullptr)
            CloseHandle(mJob);
    }

    std::optional<int> ChildProcess::exitCode()
    {
        if (!mExitCode.has_value() && WaitForSingleObject(mProcess, 0) == WAIT_OBJECT_0)
        {
            DWORD code = 0;
            GetExitCodeProcess(mProcess, &code);
            mExitCode = static_cast<int>(code);
        }
        return mExitCode;
    }

    void ChildProcess::stop(std::chrono::milliseconds /*timeout*/)
    {
        // Console programs started without a console can't be asked to stop; llama-server keeps no state to save
        if (!exitCode().has_value())
        {
            TerminateProcess(mProcess, 1);
            WaitForSingleObject(mProcess, 5000);
            exitCode();
        }
    }
#else
    ChildProcess::ChildProcess(const std::filesystem::path& executable, const std::vector<std::string>& arguments,
        const std::filesystem::path& outputFile)
    {
        // Everything the child needs is prepared before fork(): after it, only async-signal-safe calls are allowed
        const std::string executableString = executable.string();
        std::vector<std::string> argumentStrings;
        argumentStrings.push_back(executableString);
        argumentStrings.insert(argumentStrings.end(), arguments.begin(), arguments.end());
        std::vector<char*> argv;
        for (std::string& argument : argumentStrings)
            argv.push_back(argument.data());
        argv.push_back(nullptr);

        const int output = open(outputFile.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (output < 0)
            throw std::runtime_error("cannot write " + Files::pathToUnicodeString(outputFile));
        const int devNull = open("/dev/null", O_RDONLY | O_CLOEXEC);
#ifdef __linux__
        const pid_t parent = getpid();
#endif

        mPid = fork();
        if (mPid == 0)
        {
#ifdef __linux__
            // Stop with the game, even if it crashes. Tied to the forking thread, which lives as long as the server.
            prctl(PR_SET_PDEATHSIG, SIGTERM);
            if (getppid() != parent)
                _exit(127);
#endif
            if (devNull >= 0)
                dup2(devNull, STDIN_FILENO);
            dup2(output, STDOUT_FILENO);
            dup2(output, STDERR_FILENO);
            execv(argv[0], argv.data());
            _exit(127);
        }
        const int forkError = errno;
        close(output);
        if (devNull >= 0)
            close(devNull);
        if (mPid < 0)
            throw std::runtime_error("cannot start " + executableString + ": " + std::strerror(forkError));
    }

    ChildProcess::~ChildProcess()
    {
        stop(sStopTimeout);
    }

    std::optional<int> ChildProcess::exitCode()
    {
        if (!mExitCode.has_value())
        {
            int status = 0;
            if (waitpid(mPid, &status, WNOHANG) == mPid)
                mExitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        }
        return mExitCode;
    }

    void ChildProcess::stop(std::chrono::milliseconds timeout)
    {
        if (exitCode().has_value())
            return;
        kill(mPid, SIGTERM);
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        while (!exitCode().has_value() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (!exitCode().has_value())
        {
            kill(mPid, SIGKILL);
            int status = 0;
            waitpid(mPid, &status, 0);
            mExitCode = 128 + SIGKILL;
        }
    }
#endif

    LlmServer::LlmServer(Paths paths)
        : mPaths(std::move(paths))
        , mPort(Settings::llm().mPort)
    {
        mStatus.mContextSize = Settings::llm().mContextSize;
        mThread = std::jthread([this](std::stop_token stopToken) { run(stopToken); });
    }

    LlmServer::~LlmServer()
    {
        mThread.request_stop();
        mWake.notify_all();
        mThread.join();
        if (mProcess != nullptr)
        {
            Log(Debug::Info) << "Stopping llama-server";
            mProcess.reset();
        }
    }

    LlmServer::Status LlmServer::status() const
    {
        std::lock_guard lock(mMutex);
        return mStatus;
    }

    std::string_view LlmServer::stateName(State state)
    {
        switch (state)
        {
            case State::Disabled:
                return "disabled";
            case State::Starting:
                return "starting";
            case State::Ready:
                return "ready";
            case State::External:
                return "external";
            case State::NoModel:
                return "noModel";
            case State::Failed:
                return "failed";
        }
        throw std::logic_error("Unknown LLM server state");
    }

    std::string LlmServer::chooseDevice(std::string_view listDevicesOutput)
    {
        // Lines look like "  CUDA0: NVIDIA GeForce RTX 4090 (24076 MiB, 23000 MiB free)"
        static const std::regex deviceLine(R"(^\s+([A-Za-z]+)(\d+):\s)");
        static constexpr std::array preferred{ "CUDA", "ROCm", "Vulkan", "Metal" };
        std::vector<std::pair<std::string, std::string>> devices; // backend, name
        std::istringstream lines{ std::string(listDevicesOutput) };
        std::string line;
        while (std::getline(lines, line))
        {
            std::smatch match;
            if (std::regex_search(line, match, deviceLine))
                devices.emplace_back(match[1].str(), match[1].str() + match[2].str());
        }
        for (std::string_view backend : preferred)
            for (const auto& [deviceBackend, name] : devices)
                if (deviceBackend == backend)
                    return name;
        return "cpu";
    }

    std::vector<std::string> LlmServer::splitArguments(std::string_view arguments)
    {
        std::vector<std::string> result;
        std::istringstream stream{ std::string(arguments) };
        std::string argument;
        while (stream >> argument)
            result.push_back(argument);
        return result;
    }

    void LlmServer::setStatus(State state, std::string error)
    {
        if (!error.empty())
            Log(Debug::Warning) << "LLM server: " << error;
        else
            Log(Debug::Info) << "LLM server: " << stateName(state);
        std::lock_guard lock(mMutex);
        mStatus.mState = state;
        mStatus.mError = std::move(error);
    }

    bool LlmServer::sleep(std::stop_token stopToken, std::chrono::milliseconds duration)
    {
        std::unique_lock lock(mMutex);
        mWake.wait_for(lock, stopToken, duration, [] { return false; });
        return !stopToken.stop_requested();
    }

    void LlmServer::run(std::stop_token stopToken)
    {
        try
        {
            const int configuredPort = Settings::llm().mPort;
            if (checkHealth(configuredPort) != Health::None)
            {
                Log(Debug::Info) << "LLM server: using the server already running on port " << configuredPort;
                setStatus(State::External);
                while (checkHealth(configuredPort) == Health::Loading)
                    if (!sleep(stopToken, sPollInterval))
                        return;
                if (std::optional<int> contextSize = fetchContextSize(configuredPort))
                {
                    std::lock_guard lock(mMutex);
                    mStatus.mContextSize = *contextSize;
                }
                return;
            }
            if (!Settings::llm().mServerAutostart)
            {
                setStatus(State::Disabled);
                return;
            }
            if (!startBundled(stopToken))
                return;

            // Watch for the server stopping on its own
            while (sleep(stopToken, sWatchInterval))
            {
                if (std::optional<int> code = mProcess->exitCode())
                {
                    setStatus(State::Failed,
                        "llama-server stopped unexpectedly (exit code " + std::to_string(*code)
                            + "), see llama-server.log");
                    return;
                }
            }
        }
        catch (const std::exception& e)
        {
            setStatus(State::Failed, e.what());
        }
    }

    bool LlmServer::startBundled(std::stop_token stopToken)
    {
        const std::optional<std::filesystem::path> model = findModel(mPaths.mUserDataDir);
        if (!model.has_value())
        {
            setStatus(State::NoModel,
                "no model found: set [LLM] model, or put a .gguf file in "
                    + Files::pathToUnicodeString(mPaths.mUserDataDir / "models"));
            return false;
        }
        if (!std::filesystem::exists(*model))
        {
            setStatus(State::NoModel, "model file not found: " + Files::pathToUnicodeString(*model));
            return false;
        }
        const std::filesystem::path server = findServer(mPaths.mExecutableDir);
        if (!std::filesystem::exists(server))
        {
            setStatus(State::Failed, "llama-server not found: " + Files::pathToUnicodeString(server));
            return false;
        }

        std::string device = Settings::llm().mDevice;
        if (device.empty() || device == "auto")
        {
            const std::filesystem::path devicesFile = mPaths.mLogDir / "llama-server-devices.txt";
            {
                ChildProcess listDevices(server, { "--list-devices" }, devicesFile);
                const auto deadline = std::chrono::steady_clock::now() + sListDevicesTimeout;
                while (!listDevices.exitCode().has_value() && std::chrono::steady_clock::now() < deadline)
                    if (!sleep(stopToken, std::chrono::milliseconds(50)))
                        return false;
            }
            device = chooseDevice(readFile(devicesFile));
        }

        const int contextSize = Settings::llm().mContextSize;
        std::vector<std::string> arguments{ "--model", model->string(), "--ctx-size", std::to_string(contextSize),
            "--parallel", "1", "--host", sHost };
        if (device == "cpu")
            arguments.insert(arguments.end(), { "--device", "none", "--n-gpu-layers", "0" });
        else
            arguments.insert(arguments.end(),
                { "--device", device, "--n-gpu-layers", std::to_string(Settings::llm().mGpuLayers.get()) });

        const std::optional<int> port = findFreePort(Settings::llm().mPort);
        if (!port.has_value())
        {
            setStatus(State::Failed, "no free port for llama-server");
            return false;
        }
        arguments.insert(arguments.end(), { "--port", std::to_string(*port) });
        for (std::string& argument : splitArguments(Settings::llm().mExtraArguments.get()))
            arguments.push_back(std::move(argument));

        const std::string modelName = Files::pathToUnicodeString(model->filename());
        {
            std::lock_guard lock(mMutex);
            mStatus.mModel = modelName;
            mStatus.mDevice = device;
            mStatus.mContextSize = contextSize;
        }
        mPort = *port;
        setStatus(State::Starting);
        Log(Debug::Info) << "Starting llama-server on port " << *port << " with " << modelName << " on " << device
                         << ", context " << contextSize;
        mProcess = std::make_unique<ChildProcess>(server, arguments, mPaths.mLogDir / "llama-server.log");

        const auto deadline = std::chrono::steady_clock::now() + sLoadTimeout;
        while (true)
        {
            if (!sleep(stopToken, sPollInterval))
                return false;
            if (std::optional<int> code = mProcess->exitCode())
            {
                setStatus(State::Failed,
                    "llama-server exited while loading (exit code " + std::to_string(*code)
                        + "), see llama-server.log");
                return false;
            }
            if (checkHealth(*port) == Health::Ready)
                break;
            if (std::chrono::steady_clock::now() > deadline)
            {
                setStatus(State::Failed, "llama-server did not finish loading, see llama-server.log");
                return false;
            }
        }
        if (std::optional<int> reported = fetchContextSize(*port))
        {
            std::lock_guard lock(mMutex);
            mStatus.mContextSize = *reported;
        }
        setStatus(State::Ready);
        return true;
    }
}
