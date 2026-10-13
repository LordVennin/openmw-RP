#ifndef MWLUA_LLMSERVER_H
#define MWLUA_LLMSERVER_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace MWLua
{
    class ChildProcess;

    // Starts the bundled llama-server as a hidden child process when the game starts, waits until it is
    // ready, and stops it on exit. If a server already answers on the configured port, that server is used.
    // All the work happens on a monitor thread; status() and port() can be called from any thread.
    class LlmServer
    {
    public:
        enum class State
        {
            Disabled, // autostart is off: requests go to the configured port
            Starting, // the bundled server is loading the model
            Ready, // the bundled server answers
            External, // a server that was already running answers
            NoModel, // no model file was found
            Failed, // the bundled server could not be started or stopped unexpectedly
        };

        struct Status
        {
            State mState = State::Starting;
            int mContextSize = 0; // as reported by the server, or the setting until known
            std::string mModel; // model file name
            std::string mDevice; // device the model runs on ("cpu" or a llama.cpp device name)
            std::string mError;
        };

        struct Paths
        {
            std::filesystem::path mExecutableDir; // where the bundled "llama" folder and the default models folder are
            std::filesystem::path mUserDataDir; // where models are if the game's folder is not writable
            std::filesystem::path mLogDir; // where llama-server.log is written
        };

        explicit LlmServer(Paths paths);
        ~LlmServer();

        LlmServer(const LlmServer&) = delete;
        LlmServer& operator=(const LlmServer&) = delete;

        Status status() const;

        // Port requests should go to
        int port() const { return mPort; }

        static std::string_view stateName(State state);

    private:
        void run(std::stop_token stopToken);
        bool startBundled(std::stop_token stopToken);
        void setStatus(State state, std::string error = {});
        // Sleeps up to `duration`, waking early on stop. Returns false if stopped.
        bool sleep(std::stop_token stopToken, std::chrono::milliseconds duration);

        const Paths mPaths;
        std::atomic<int> mPort;

        mutable std::mutex mMutex;
        std::condition_variable_any mWake;
        Status mStatus;

        std::unique_ptr<ChildProcess> mProcess; // monitor thread only, and the destructor after joining it

        // Declared last so that the thread starts after, and is joined before, the members it uses.
        std::jthread mThread;
    };
}

#endif // MWLUA_LLMSERVER_H
