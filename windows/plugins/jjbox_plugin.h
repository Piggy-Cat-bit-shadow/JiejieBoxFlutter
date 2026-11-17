#pragma once

#include <flutter/plugin_registrar_windows.h>

// Posted by the bridge worker after a host call completes. The runner calls
// JjboxPluginDrainCompletions() from its top-level WindowProc; this keeps the
// MethodResult on the platform thread.
constexpr UINT kJjboxPluginCompletionMessage = WM_APP + 0x4A;

// Registers the app-local bridge plugin with the runner's engine. The runner
// calls this right after the generated plugin registrant, because the bridge is
// part of the application rather than a pub package (it ships with this fork).
void JjboxPluginRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

// Drains completed host calls on the platform thread. Safe when no plugin is
// registered (for example during shutdown).
void JjboxPluginDrainCompletions();
