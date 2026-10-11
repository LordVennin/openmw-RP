#include "llmbindings.hpp"

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>

#include <components/lua/asyncpackage.hpp>
#include <components/lua/luastate.hpp>

#include "context.hpp"
#include "luamanagerimp.hpp"

namespace MWLua
{
    namespace
    {
        constexpr double sDefaultTimeoutSeconds = 120;
        constexpr double sMinTimeoutSeconds = 1;
        constexpr double sMaxTimeoutSeconds = 600;

        LlmClient::Endpoint parseEndpoint(std::string_view name)
        {
            if (name == "chat")
                return LlmClient::Endpoint::ChatCompletions;
            if (name == "completion")
                return LlmClient::Endpoint::Completion;
            throw std::runtime_error("Unknown LLM endpoint '" + std::string(name) + "', expected 'chat' or 'completion'");
        }
    }

    sol::table initLlmPackage(const Context& context)
    {
        sol::state_view lua = context.sol();
        sol::table api(lua, sol::create);
        api["ping"] = []() -> std::string { return "pong"; };

        api["request"] = [context, lua](std::string body, const sol::table& callback,
                             const sol::optional<sol::table>& options) -> std::tuple<sol::object, sol::object> {
            double timeout = sDefaultTimeoutSeconds;
            LlmClient::Endpoint endpoint = LlmClient::Endpoint::ChatCompletions;
            if (options.has_value())
            {
                timeout = options->get_or("timeout", sDefaultTimeoutSeconds);
                if (sol::optional<std::string_view> name = (*options)["endpoint"])
                    endpoint = parseEndpoint(*name);
            }
            timeout = std::clamp(timeout, sMinTimeoutSeconds, sMaxTimeoutSeconds);

            std::optional<int> id = context.mLuaManager->llmClient().request(endpoint, std::move(body),
                LuaUtil::Callback::fromLua(callback), std::chrono::seconds(static_cast<int>(timeout)));
            if (!id.has_value())
                return { sol::nil, sol::make_object(lua, "too many pending requests") };
            return { sol::make_object(lua, *id), sol::nil };
        };

        api["cancel"] = [context](int id) { return context.mLuaManager->llmClient().cancel(id); };

        return LuaUtil::makeReadOnly(api);
    }
}
