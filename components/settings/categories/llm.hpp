#ifndef OPENMW_COMPONENTS_SETTINGS_CATEGORIES_LLM_H
#define OPENMW_COMPONENTS_SETTINGS_CATEGORIES_LLM_H

#include <components/settings/sanitizerimpl.hpp>
#include <components/settings/settingvalue.hpp>

#include <string>

namespace Settings
{
    struct LlmCategory : WithIndex
    {
        using WithIndex::WithIndex;

        SettingValue<bool> mServerAutostart{ mIndex, "LLM", "server autostart" };
        SettingValue<std::string> mServerPath{ mIndex, "LLM", "server path" };
        SettingValue<std::string> mModelsFolder{ mIndex, "LLM", "models folder" };
        SettingValue<std::string> mModel{ mIndex, "LLM", "model" };
        SettingValue<std::string> mDevice{ mIndex, "LLM", "device" };
        SettingValue<int> mContextSize{ mIndex, "LLM", "context size", makeClampSanitizerInt(2048, 1048576) };
        SettingValue<int> mGpuLayers{ mIndex, "LLM", "gpu layers", makeClampSanitizerInt(-1, 999) };
        SettingValue<int> mVramReserveMiB{ mIndex, "LLM", "vram reserve", makeClampSanitizerInt(0, 65536) };
        SettingValue<int> mPort{ mIndex, "LLM", "port", makeClampSanitizerInt(1, 65535) };
        SettingValue<std::string> mExtraArguments{ mIndex, "LLM", "extra arguments" };
    };
}

#endif
