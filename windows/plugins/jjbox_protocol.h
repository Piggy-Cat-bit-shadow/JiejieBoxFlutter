// The frame every Windows side of the bridge shares: the Flutter plugin, the Go
// host process and their tests. One definition, no second copy.
#pragma once

#include <cstdint>

namespace jjbox {

constexpr char kCommandsChannel[] = "jjbox/host";
constexpr char kCallbacksChannel[] = "jjbox/host/callback";
constexpr char kInvokeMethod[] = "jjbox.invoke";

// A request or a response is one JSON envelope; the payload stays opaque UTF-8 so
// the C++ side never needs a JSON parser.
constexpr uint32_t kMaxPayloadBytes = 8u * 1024u * 1024u;

#pragma pack(push, 1)
struct FrameHeader {
  uint32_t length;    // payload bytes, little endian, <= kMaxPayloadBytes
  uint32_t reserved;  // must be zero
};
#pragma pack(pop)

static_assert(sizeof(FrameHeader) == 8, "the frame header is fixed");

}  // namespace jjbox
