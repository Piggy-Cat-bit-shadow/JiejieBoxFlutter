#pragma once

#include <flutter/plugin_registrar_windows.h>

// Registers the bridge plugin with the runner's engine. The runner calls this
// right after the generated plugin registrant, because the bridge is part of the
// application rather than a pub package (it ships with this fork).
void JjboxPluginRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
