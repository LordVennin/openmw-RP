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

    std::optional<int> LlmClient::request(
        Endpoint endpoint, std::string body, LuaUtil::Callback callback, std::chrono::seconds timeout)
    {
        int id;
        {
            std::lock_guard lock(mMutex);
            if (mPending.size() >= sMaxPending)
                return std::nullopt;
            id = mNextId++;
            const int port = mServer != nullptr ? mServer->port() : Settings::llm().mPort.get();
            mPending.push_back(Job{ id, port, endpoint, std::move(body), timeout });
        }
        mCallbacks.emplace(id, std::move(callback));
        mCondition.notify_one();
        return id;
    }

    bool LlmClient::cancel(int id)
    {
        if (mCallbacks.erase(id) == 0)
            return false;
        std::lock_guard lock(mMutex);
        if (mRunningId == id)
            stopRunningRequest();
        else
            std::erase_if(mPending, [id](const Job& job) { return job.mId == id; });
        return true;
    }

    void LlmClient::cancelAll()
    {
        mCallbacks.clear();
        std::lock_guard lock(mMutex);
        mPending.clear();
        mFinished.clear();
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
        {
            std::lock_guard lock(mMutex);
            finished.swap(mFinished);
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
        }
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

            httplib::Result response = client.Post(getPath(job.mEndpoint), job.mBody, "application/json",
                [this](std::size_t /*current*/, std::size_t /*total*/) { return !mRunningCancelled; });

            Result result{ job.mId, 0, {}, {} };
            if (response)
            {
                result.mStatus = response->status;
                result.mBody = std::move(response->body);
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
