#include "llmbindings.hpp"

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>

#include <components/lua/asyncpackage.hpp>
#include <components/lua/luastate.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwgui/dialogue.hpp"
#include "../mwgui/mode.hpp"

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

        // Dialogue window integration. GUI changes are queued to run on the main thread.
        api["setDialogueInput"] = [context](const sol::table& options) {
            const bool visible = options.get_or("visible", true);
            const bool enabled = options.get_or("enabled", true);
            std::string hint = options.get_or<std::string>("hint", {});
            std::string recallLabel = options.get_or<std::string>("recallLabel", {});
            context.mLuaManager->addAction(
                [visible, enabled, hint = std::move(hint), recallLabel = std::move(recallLabel)] {
                    MWBase::Environment::get().getWindowManager()->getDialogueWindow()->setTextInput(
                        visible, enabled, hint, recallLabel);
                },
                "setDialogueInputAction");
        };

        api["setDialogueChoices"] = [context](const sol::optional<sol::table>& list) {
            std::vector<std::pair<std::string, std::string>> choices;
            if (list.has_value())
            {
                for (size_t i = 1; i <= list->size(); ++i)
                {
                    sol::object value = (*list)[i];
                    if (!value.is<sol::table>())
                        continue;
                    sol::table choice = value.as<sol::table>();
                    choices.emplace_back(choice.get_or<std::string>("id", {}), choice.get_or<std::string>("label", {}));
                }
            }
            context.mLuaManager->addAction(
                [choices = std::move(choices)]() mutable {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (windowManager->containsMode(MWGui::GM_Dialogue))
                        windowManager->getDialogueWindow()->setLuaChoices(std::move(choices));
                },
                "setDialogueChoicesAction");
        };

        api["addDialogueResponse"] = [context](std::string text, const sol::optional<sol::table>& options) {
            std::string title;
            if (options.has_value())
                title = options->get_or<std::string>("title", {});
            context.mLuaManager->addAction(
                [text = std::move(text), title = std::move(title)] {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (windowManager->containsMode(MWGui::GM_Dialogue))
                        windowManager->getDialogueWindow()->addResponse(title, text);
                },
                "addDialogueResponseAction");
        };

        return LuaUtil::makeReadOnly(api);
    }
}
