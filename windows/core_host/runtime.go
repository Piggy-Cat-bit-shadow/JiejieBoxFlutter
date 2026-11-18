package main

// Runtime data bridge: the pieces that do not need the libbox build tag.
//
// The host already has a request/response protocol and an event queue. This file adds
// the runtime surface the contract (OUTPUT_CLOSEOUT/CONTRACTS/RUNTIME_CONTRACT.md)
// describes: a sink for kernel-pushed events, the optional interface a linked core
// implements, and the redaction a log line goes through before it leaves the host.

import (
	"crypto/rand"
	"encoding/hex"
	"regexp"
	"strings"
)

// Event types the runtime bridge emits. They are part of RUNTIME_CONTRACT v1; renaming
// one is a contract change, not a refactor.
const (
	eventRuntimeStatus      = "runtime.status"
	eventRuntimeGroups      = "runtime.groups"
	eventRuntimeLog         = "runtime.log"
	eventRuntimeConnections = "runtime.connections"
	eventRuntimeModes       = "runtime.modes"
	eventLogsCleared        = "logs.cleared"
)

// eventSink receives one runtime event. The host supplies a sink that stamps the
// source epoch and queues the frame; the linked core only knows how to produce data.
type eventSink func(kind string, data map[string]any)

// runtimeAPI is implemented by a linked core. It is deliberately separate from coreAPI:
// the default (unlinked) build must answer "unsupported" for runtime commands without
// pretending the kernel is stopped, and Go's structural typing makes the absence of this
// interface an honest capability signal.
type runtimeAPI interface {
	SubscribeRuntime(sink eventSink) error
	UnsubscribeRuntime()
	SelectOutbound(groupTag, outboundTag, requestID string, expectedRevision int64) (map[string]any, *bridgeError)
	URLTest(groupTag, outboundTag string) (map[string]any, *bridgeError)
	URLTestCancel(groupTag string) (map[string]any, *bridgeError)
	SetMode(mode string) (map[string]any, *bridgeError)
	Modes() (map[string]any, *bridgeError)
	RefreshProviders(tags []string, timeoutMillis int64) (map[string]any, *bridgeError)
	CloseConnection(id string) (map[string]any, *bridgeError)
	CloseConnections() (map[string]any, *bridgeError)
}

// newHostEpoch returns the identity of this host process. A restart produces a new one,
// which is how the Dart side tells "the same host reconnected" from "a new host".
func newHostEpoch() string {
	var buffer [8]byte
	if _, err := rand.Read(buffer[:]); err != nil {
		return "epoch-unavailable"
	}
	return hex.EncodeToString(buffer[:])
}

var (
	// Values of these keys are replaced before a log line leaves the host. The pattern
	// keeps the key (which is diagnostic) and drops the value (which is a credential).
	logCredentialPattern = regexp.MustCompile(`(?i)\b(password|passwd|token|secret|uuid|psk|private[_-]?key|authorization)\s*[=:]\s*("[^"]*"|'[^']*'|\S+)`)
	// A subscription link carries its credential in the userinfo part; the whole link is
	// replaced because partial masking still leaks the host and path.
	logLinkPattern = regexp.MustCompile(`\b(trojan|vless|vmess|ss|ssr|tuic|hysteria2?|anytls|snell)://\S+`)
)

// redactLog removes credentials from one kernel log line. It is pure and tested without
// libbox so the default build can prove the behaviour too.
func redactLog(message string) string {
	message = logLinkPattern.ReplaceAllString(message, "$1://***")
	message = logCredentialPattern.ReplaceAllString(message, "$1=***")
	// Kernel errors occasionally echo a whole document; keep the line bounded so one bad
	// line cannot flood the ring or the event channel.
	if len(message) > 2000 {
		message = message[:2000] + "..."
	}
	return message
}

// logLevelName maps sing-box's numeric level to the name the contract uses. Unknown
// values are reported as "unknown" rather than guessed.
func logLevelName(level int32) string {
	switch level {
	case 0:
		return "trace"
	case 1:
		return "debug"
	case 2:
		return "info"
	case 3:
		return "warn"
	case 4:
		return "error"
	case 5:
		return "fatal"
	default:
		return "unknown"
	}
}

// trimForEvent bounds a string that is about to enter the event queue.
func trimForEvent(text string, limit int) string {
	text = strings.ToValidUTF8(text, "?")
	if len(text) <= limit {
		return text
	}
	return text[:limit] + "..."
}
