#include "llmbindings.hpp"

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>

#include <components/esm3/loaddial.hpp>
#include <components/interpreter/defines.hpp>
#include <components/lua/asyncpackage.hpp>
#include <components/lua/luastate.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/dialoguemanager.hpp"
#include "../mwbase/environment.hpp"
#include "../mwdialogue/filter.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwscript/interpretercontext.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwgui/dialogue.hpp"
#include "../mwgui/mode.hpp"

#include "context.hpp"
#include "luamanagerimp.hpp"
#include "object.hpp"

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

        // The Lua state comes in as sol::this_state: a captured sol::state_view would hold a registry reference that is
        // released while Lua closes at exit, which crashes
        api["request"] = [context](sol::this_state lua, std::string body, const sol::table& callback,
                             const sol::optional<sol::table>& options) -> std::tuple<sol::object, sol::object> {
            double timeout = sDefaultTimeoutSeconds;
            LlmClient::Endpoint endpoint = LlmClient::Endpoint::ChatCompletions;
            // stream = async:callback(function(payloads) ... end): read the reply as server-sent events
            std::optional<LuaUtil::Callback> onChunk;
            if (options.has_value())
            {
                timeout = options->get_or("timeout", sDefaultTimeoutSeconds);
                if (sol::optional<std::string_view> name = (*options)["endpoint"])
                    endpoint = parseEndpoint(*name);
                if (sol::optional<sol::table> stream = (*options)["stream"])
                    onChunk = LuaUtil::Callback::fromLua(*stream);
            }
            timeout = std::clamp(timeout, sMinTimeoutSeconds, sMaxTimeoutSeconds);

            std::optional<int> id = context.mLuaManager->llmClient().request(endpoint, std::move(body),
                LuaUtil::Callback::fromLua(callback), std::chrono::seconds(static_cast<int>(timeout)), std::move(onChunk));
            if (!id.has_value())
                return { sol::nil, sol::make_object(lua, "too many pending requests") };
            return { sol::make_object(lua, *id), sol::nil };
        };

        api["cancel"] = [context](int id) { return context.mLuaManager->llmClient().cancel(id); };

        api["serverStatus"] = [context](sol::this_state lua) {
            sol::table result(lua, sol::create);
            const LlmServer* server = context.mLuaManager->llmServer();
            if (server == nullptr)
            {
                result["state"] = "disabled";
                result["contextSize"] = Settings::llm().mContextSize.get();
                return result;
            }
            LlmServer::Status status = server->status();
            result["state"] = LlmServer::stateName(status.mState);
            result["contextSize"] = status.mContextSize;
            if (!status.mModel.empty())
                result["model"] = std::move(status.mModel);
            if (!status.mDevice.empty())
                result["device"] = std::move(status.mDevice);
            if (!status.mError.empty())
                result["error"] = std::move(status.mError);
            return result;
        };

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

        // Vanilla's service refusal for an actor: what DialogueManager::checkServiceRefused would answer when the player
        // asks for `service` (MWBase::DialogueManager::ServiceType: 1 barter, 2 repair, 3 spells, 4 training, 5 travel,
        // 6 spellmaking, 7 enchanting). Like vanilla, the refusals for any service are checked first. Returns the
        // refusal line, or nil if the actor would provide the service. Doesn't run the line's result script.
        api["serviceRefusal"] = [](const Object& actor, int service) -> sol::optional<std::string> {
            const MWWorld::Ptr ptr = actor.ptr();
            if (!ptr.getClass().isActor())
                return sol::nullopt;
            const ESM::Dialogue* dialogue
                = MWBase::Environment::get().getESMStore()->get<ESM::Dialogue>().search(
                    ESM::RefId::stringRefId("Service Refusal"));
            if (!dialogue)
                return sol::nullopt;
            const bool talkedTo = ptr.getClass().getCreatureStats(ptr).hasTalkedToPlayer();
            for (int choice : { -1, service })
            {
                MWDialogue::Filter filter(ptr, choice, talkedTo);
                const std::vector<MWDialogue::Filter::Response> infos = filter.list(*dialogue, false, false, true);
                if (!infos.empty())
                {
                    MWScript::InterpreterContext interpreterContext(&ptr.getRefData().getLocals(), ptr);
                    return Interpreter::fixDefinesDialog(infos[0].second->mResponse, interpreterContext);
                }
            }
            return sol::nullopt;
        };

        // A response that grows while the NPC's reply streams in: the first call adds it to the dialogue history,
        // later calls replace its text, until endDialogueResponse()
        api["setDialogueResponse"] = [context](std::string text) {
            context.mLuaManager->addAction(
                [text = std::move(text)] {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (windowManager->containsMode(MWGui::GM_Dialogue))
                        windowManager->getDialogueWindow()->setLiveResponse(text);
                },
                "setDialogueResponseAction");
        };

        api["endDialogueResponse"] = [context]() {
            context.mLuaManager->addAction(
                [] {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (windowManager->containsMode(MWGui::GM_Dialogue))
                        windowManager->getDialogueWindow()->endLiveResponse();
                },
                "endDialogueResponseAction");
        };

        // Vanilla's topic learning for text the NPC said (an AI reply): topics named in it that the NPC in the open
        // dialogue has an answer for become known, as with vanilla responses
        api["addTopicsFromText"] = [context](std::string text) {
            context.mLuaManager->addAction(
                [text = std::move(text)] {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (!windowManager->containsMode(MWGui::GM_Dialogue))
                        return;
                    MWBase::Environment::get().getDialogueManager()->addTopicsFromText(text);
                    windowManager->getDialogueWindow()->refreshTopics();
                },
                "addTopicsFromTextAction");
        };

        // Whether the player knows a topic, the gate vanilla puts on lines written for one NPC: a topic can only be
        // asked about once it's known
        api["isTopicKnown"] = [](std::string_view topicId) {
            return MWBase::Environment::get().getDialogueManager()->isTopicKnown(ESM::RefId::deserializeText(topicId));
        };

        api["setDialogueBusy"] = [context](bool busy) {
            context.mLuaManager->addAction(
                [busy] {
                    MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
                    if (windowManager->containsMode(MWGui::GM_Dialogue))
                        windowManager->getDialogueWindow()->setLuaBusy(busy);
                },
                "setDialogueBusyAction");
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
