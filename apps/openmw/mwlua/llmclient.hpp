#ifndef MWLUA_LLMCLIENT_H
#define MWLUA_LLMCLIENT_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <components/lua/asyncpackage.hpp>

namespace httplib
{
    class Client;
}

namespace MWLua
{
    class LlmServer;
    class LuaManager;

    // Sends chat requests from the openmw.llm package to a local LLM server (e.g. llama-server)
    // on a worker thread. The worker never touches Lua: it only sees request bodies and returns
    // plain strings, which deliverResults() turns into Lua callbacks on the Lua thread.
    class LlmClient
    {
    public:
        static constexpr std::size_t sMaxPending = 8;

        // The only server paths requests can go to.
        enum class Endpoint
        {
            ChatCompletions, // /v1/chat/completions: the server applies the model's chat template
            Completion, // /completion: raw text completion with a prompt built by the caller
        };

        LlmClient();
        ~LlmClient();

        // The functions below must only be called from the Lua thread.

        // Requests go to the server's port. Without a server, to the [LLM] port setting.
        void setServer(const LlmServer* server) { mServer = server; }

        // Queues a POST of `body` to the endpoint on 127.0.0.1.
        // With `onChunk`, the response is read as a stream of server-sent events (the body must ask the server to
        // stream): onChunk gets the events' data payloads as they arrive, at most once per frame, and the final
        // callback gets the last payload as its body.
        // Returns the request id, or std::nullopt if sMaxPending requests are already waiting.
        std::optional<int> request(Endpoint endpoint, std::string body, LuaUtil::Callback callback,
            std::chrono::seconds timeout, std::optional<LuaUtil::Callback> onChunk = std::nullopt);

        // Drops the request's callback and aborts it if it is queued or running.
        // Returns false if the request is unknown or its callback was already queued.
        bool cancel(int id);

        // Cancels every request. Called when the game is cleared (load or new game).
        void cancelAll();

        // Queues the callbacks of finished requests on the LuaManager.
        void deliverResults(sol::state_view lua, LuaManager& manager);

    private:
        struct Job
        {
            int mId;
            int mPort;
            Endpoint mEndpoint;
            std::string mBody;
            std::chrono::seconds mTimeout;
            bool mStream;
        };

        struct Result
        {
            int mId;
            int mStatus;
            std::string mBody;
            std::string mError;
        };

        void run(std::stop_token stopToken);
        void stopRunningRequest();
        // Worker thread: adds the complete events in `buffer` to mChunks, keeping an incomplete one
        void takeEvents(int id, std::string& buffer, std::string& last);

        // Lua thread only.
        const LlmServer* mServer = nullptr;
        std::map<int, LuaUtil::Callback> mCallbacks;
        std::map<int, LuaUtil::Callback> mChunkCallbacks;
        int mNextId = 1;

        // Shared with the worker thread, guarded by mMutex.
        std::mutex mMutex;
        std::condition_variable_any mCondition;
        std::deque<Job> mPending;
        std::vector<Result> mFinished;
        // Streamed event payloads not yet delivered, by request id
        std::map<int, std::vector<std::string>> mChunks;
        std::optional<int> mRunningId;
        // Points to a client on the worker's stack. The worker clears it under mMutex before the client
        // is destroyed, so it is only valid to use while holding mMutex.
        httplib::Client* mRunningClient = nullptr;
        // Checked by the upload progress callback to abort a request that was cancelled before
        // httplib marked its socket as in flight, when Client::stop() has no effect yet.
        std::atomic<bool> mRunningCancelled = false;

        // Declared last so that the thread starts after, and is joined before, the members it uses.
        std::jthread mThread;
    };
}

#endif // MWLUA_LLMCLIENT_H
