#ifndef MWLUA_LLMBINDINGS_H
#define MWLUA_LLMBINDINGS_H

#include <sol/forward.hpp>

namespace MWLua
{
    struct Context;

    sol::table initLlmPackage(const Context& context);
}

#endif // MWLUA_LLMBINDINGS_H
