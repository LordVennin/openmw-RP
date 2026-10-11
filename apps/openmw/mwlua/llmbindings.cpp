#include "llmbindings.hpp"

#include <string>

#include <components/lua/luastate.hpp>

#include "context.hpp"

namespace MWLua
{
    sol::table initLlmPackage(const Context& context)
    {
        sol::table api(context.sol(), sol::create);
        api["ping"] = []() -> std::string { return "pong"; };
        return LuaUtil::makeReadOnly(api);
    }
}
