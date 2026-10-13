#include "llmclient.hpp"

#include <stdexcept>
#include <utility>

#include <httplib.h>
#ifdef __APPLE__
// macOS headers pulled in by httplib define nil, which breaks sol::nil
#undef nil
#endif

#include <components/settings/values.hpp>

#include "llmserver.hpp"
#include "luamanagerimp.hpp"

namespace MWLua
{
    namespace
    {
        constexpr const char* sHost = "127.0.0.1";
        constexpr time_t sConnectionTimeoutSeconds = 2;

        const char* getPath(LlmClient::Endpoint endpoint)
        {
            switch (endpoint)
            {
                case LlmClient::Endpoint::ChatCompletions:
                    return "/v1/chat/completions";
                case LlmClient::Endpoint::Completion:
                    return "/completion";
            }
            throw std::logic_error("Unknown LLM endpoint");
        }
    }

    LlmClient::LlmClient()
    {
        mThread = std::jthread([this](std::stop_token stopToken) { run(stopToken); });
    }

    LlmClient::~LlmClient()
    {
        mThread.request_stop();
        {
            std::lock_guard lock(mMutex);
            mPending.clear();
            stopRunningRequest();
        }
        mThread.join();
    }

    std::optional<int> LlmClient::request(Endpoint endpoint, std::string body, LuaUtil::Callback callback,
        std::chrono::seconds timeout, std::optional<LuaUtil::Callback> onChunk)
    {
        int id;
        {
            std::lock_guard lock(mMutex);
            if (mPending.size() >= sMaxPending)
                return std::nullopt;
            id = mNextId++;
            const int port = mServer != nullptr ? mServer->port() : Settings::llm().mPort.get();
            mPending.push_back(Job{ id, port, endpoint, std::move(body), timeout, onChunk.has_value() });
        }
        mCallbacks.emplace(id, std::move(callback));
        if (onChunk.has_value())
            mChunkCallbacks.emplace(id, std::move(*onChunk));
        mCondition.notify_one();
        return id;
    }

    bool LlmClient::cancel(int id)
    {
        if (mCallbacks.erase(id) == 0)
            return false;
        mChunkCallbacks.erase(id);
        std::lock_guard lock(mMutex);
        mChunks.erase(id);
        if (mRunningId == id)
            stopRunningRequest();
        else
            std::erase_if(mPending, [id](const Job& job) { return job.mId == id; });
        return true;
    }

    void LlmClient::cancelAll()
    {
        mCallbacks.clear();
        mChunkCallbacks.clear();
        std::lock_guard lock(mMutex);
        mPending.clear();
        mFinished.clear();
        mChunks.clear();
        stopRunningRequest();
    }

    void LlmClient::stopRunningRequest()
    {
        mRunningCancelled = true;
        if (mRunningClient != nullptr)
            mRunningClient->stop();
    }

    void LlmClient::deliverResults(sol::state_view lua, LuaManager& manager)
    {
        std::vector<Result> finished;
        std::map<int, std::vector<std::string>> chunks;
        {
            std::lock_guard lock(mMutex);
            finished.swap(mFinished);
            chunks.swap(mChunks);
        }
        // Chunks first: a request's last chunks always arrive before its final callback
        for (auto& [id, payloads] : chunks)
        {
            auto it = mChunkCallbacks.find(id);
            if (it == mChunkCallbacks.end())
                continue; // cancelled
            sol::table list(lua, sol::create);
            for (std::size_t i = 0; i < payloads.size(); ++i)
                list[i + 1] = std::move(payloads[i]);
            manager.queueCallback(it->second, sol::main_object(list));
        }
        for (Result& result : finished)
        {
            auto it = mCallbacks.find(result.mId);
            if (it == mCallbacks.end())
                continue; // cancelled
            sol::table res(lua, sol::create);
            res["ok"] = result.mError.empty();
            res["status"] = result.mStatus;
            res["body"] = std::move(result.mBody);
            if (!result.mError.empty())
                res["error"] = std::move(result.mError);
            manager.queueCallback(std::move(it->second), sol::main_object(res));
            mCallbacks.erase(it);
            mChunkCallbacks.erase(result.mId);
        }
    }

    void LlmClient::takeEvents(int id, std::string& buffer, std::string& last)
    {
        // Server-sent events: "data: <payload>" lines, each event ended by a blank line
        std::vector<std::string> payloads;
        std::size_t end;
        while ((end = buffer.find("\n\n")) != std::string::npos)
        {
            std::string_view event(buffer.data(), end);
            std::size_t start = 0;
            while (start < event.size())
            {
                std::size_t lineEnd = event.find('\n', start);
                if (lineEnd == std::string_view::npos)
                    lineEnd = event.size();
                std::string_view line = event.substr(start, lineEnd - start);
                if (!line.empty() && line.back() == '\r')
                    line.remove_suffix(1);
                if (line.starts_with("data:"))
                {
                    line.remove_prefix(5);
                    if (!line.empty() && line.front() == ' ')
                        line.remove_prefix(1);
                    payloads.emplace_back(line);
                }
                start = lineEnd + 1;
            }
            buffer.erase(0, end + 2);
        }
        if (payloads.empty())
            return;
        last = payloads.back();
        std::lock_guard lock(mMutex);
        if (mRunningCancelled)
            return;
        auto& queued = mChunks[id];
        for (std::string& payload : payloads)
            queued.push_back(std::move(payload));
    }

    void LlmClient::run(std::stop_token stopToken)
    {
        while (true)
        {
            std::unique_lock lock(mMutex);
            if (!mCondition.wait(lock, stopToken, [this] { return !mPending.empty(); }))
                return;

            Job job = std::move(mPending.front());
            mPending.pop_front();

            httplib::Client client(sHost, job.mPort);
            client.set_connection_timeout(sConnectionTimeoutSeconds);
            client.set_read_timeout(job.mTimeout.count());
            client.set_write_timeout(job.mTimeout.count());

            mRunningId = job.mId;
            mRunningClient = &client;
            mRunningCancelled = false;
            lock.unlock();

            httplib::Result response;
            // Streamed responses: bytes not yet split into events, and the last event's payload
            std::string buffer;
            std::string lastEvent;
            if (job.mStream)
            {
                response = client.Post(
                    getPath(job.mEndpoint), httplib::Headers{}, job.mBody, "application/json",
                    [&](const char* data, std::size_t length) {
                        buffer.append(data, length);
                        takeEvents(job.mId, buffer, lastEvent);
                        return !mRunningCancelled;
                    },
                    [this](std::size_t /*current*/, std::size_t /*total*/) { return !mRunningCancelled; });
            }
            else
            {
                response = client.Post(getPath(job.mEndpoint), job.mBody, "application/json",
                    [this](std::size_t /*current*/, std::size_t /*total*/) { return !mRunningCancelled; });
            }

            Result result{ job.mId, 0, {}, {} };
            if (response)
            {
                result.mStatus = response->status;
                // A failed streamed request still has its error message in the body
                result.mBody = job.mStream && !lastEvent.empty() ? std::move(lastEvent) : std::move(response->body);
                if (job.mStream && result.mBody.empty())
                    result.mBody = std::move(buffer);
                if (result.mStatus < 200 || result.mStatus >= 300)
                    result.mError = "HTTP " + std::to_string(result.mStatus);
            }
            else
                result.mError = httplib::to_string(response.error());

            lock.lock();
            // Must happen under the lock before `client` is destroyed, so cancel() can't call stop() on it.
            mRunningClient = nullptr;
            mRunningId.reset();
            if (!mRunningCancelled)
                mFinished.push_back(std::move(result));
        }
    }
}
