// The one constant the manifest harness needs from Code/PocketMageOS/include/elf_runner.h
// (that header pulls in the Arduino/ESP-IDF headers): elf_runner.cpp caps app.properties
// at ELF_APP_PROPERTIES_MAX_BYTES = 1024 bytes. build.sh checks the value still matches.
#pragma once
#include <stddef.h>
constexpr size_t kElfAppPropertiesMaxBytes = 1024;
