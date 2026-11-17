cmake_minimum_required(VERSION 3.14)
project(jjbox_plugin LANGUAGES CXX)

# Static on purpose: the bridge ships with the runner, so it needs no DLL export
# table and no install rule of its own.
add_library(jjbox_plugin STATIC "jjbox_plugin.cpp")
apply_standard_settings(jjbox_plugin)
target_link_libraries(jjbox_plugin PUBLIC flutter flutter_wrapper_plugin)
target_include_directories(jjbox_plugin PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
