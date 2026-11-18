package main

// Unit tests for the runtime bridge pieces that do not need the libbox build tag:
// redaction (a log line must not leak a credential), the bounded event queue, and the
// honest capability answer of the default shell.

import (
	"strings"
	"testing"
)

func TestRedactLogRemovesLinkCredentials(t *testing.T) {
	cases := []struct {
		name     string
		input    string
		mustHold []string
		mustNot  []string
	}{
		{
			name:     "trojan link",
			input:    "dialing trojan://secret-password@example.com:443#node",
			mustHold: []string{"trojan://***"},
			mustNot:  []string{"secret-password", "example.com"},
		},
		{
			name:     "ss link",
			input:    "provider node ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@198.51.100.7:8388",
			mustHold: []string{"ss://***"},
			mustNot:  []string{"YWVzLTEyOC1nY206cGFzc3dvcmQ", "198.51.100.7"},
		},
		{
			name:     "password assignment",
			input:    `config password="hunter2" applied`,
			mustHold: []string{"password=***"},
			mustNot:  []string{"hunter2"},
		},
		{
			name:     "token assignment keeps the key",
			input:    "token: abc123def456",
			mustHold: []string{"token=***"},
			mustNot:  []string{"abc123def456"},
		},
		{
			name:     "uuid and private key",
			input:    `uuid=11111111-1111-1111-1111-111111111111 private-key="abc def"`,
			mustHold: []string{"uuid=***", "private-key=***"},
			mustNot:  []string{"11111111-1111-1111-1111-111111111111", "abc def"},
		},
		{
			name:     "ordinary text survives",
			input:    "inbound mixed started on 127.0.0.1:2080",
			mustHold: []string{"inbound mixed started on 127.0.0.1:2080"},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			redacted := redactLog(testCase.input)
			for _, expected := range testCase.mustHold {
				if !strings.Contains(redacted, expected) {
					t.Fatalf("redacted %q lacks %q", redacted, expected)
				}
			}
			for _, forbidden := range testCase.mustNot {
				if strings.Contains(redacted, forbidden) {
					t.Fatalf("redacted %q still contains %q", redacted, forbidden)
				}
			}
		})
	}
}

func TestRedactLogBoundsLength(t *testing.T) {
	long := strings.Repeat("a", 5000)
	redacted := redactLog(long)
	if len(redacted) > 2003 {
		t.Fatalf("redacted line is %d bytes; the event queue must stay bounded", len(redacted))
	}
}

func TestEventQueueKeepsStateWhenFlooded(t *testing.T) {
	server := newHostServer(nil, unlinkedCore{})
	// A state change must survive the flood: losing it would leave the UI disagreeing
	// with the host forever.
	server.emit("service.state", map[string]any{"state": stateRunning})
	for index := 0; index < maxPendingEvents+500; index++ {
		server.emit(eventRuntimeStatus, map[string]any{"index": index})
	}
	if len(server.pending) != maxPendingEvents {
		t.Fatalf("queue length = %d, want %d", len(server.pending), maxPendingEvents)
	}
	foundState := false
	for _, frame := range server.pending {
		if frame["type"] == "service.state" {
			foundState = true
			break
		}
	}
	if !foundState {
		t.Fatal("the service.state frame was evicted by the flood")
	}
}

func TestDefaultShellAdvertisesNoRuntime(t *testing.T) {
	server := newHostServer(nil, unlinkedCore{})
	if server.runtime != nil {
		t.Fatal("the unlinked shell must not advertise a runtime bridge")
	}
	capabilities := server.Handle(request{ID: "1", Method: "host.capabilities"})
	result, _ := capabilities.Result.(map[string]any)
	if result["runtime"] != false {
		t.Fatalf("capabilities.runtime = %v, want false", result["runtime"])
	}
	if result["hostEpoch"] == "" {
		t.Fatal("capabilities must carry a hostEpoch so cached frames can be invalidated")
	}
	for _, method := range []string{"group.select", "group.urlTest", "mode.set", "connections.close", "provider.refresh"} {
		response := server.Handle(request{ID: method, Method: method, Args: map[string]any{}})
		if response.OK {
			t.Fatalf("%s must not succeed without a linked core", method)
		}
		if response.Error.Code != "unsupported_platform" {
			t.Fatalf("%s error = %q, want unsupported_platform", method, response.Error.Code)
		}
	}
}

func TestLogLevelNamesCoverTheKernelRange(t *testing.T) {
	for level, expected := range map[int32]string{0: "trace", 1: "debug", 2: "info", 3: "warn", 4: "error", 5: "fatal", 9: "unknown"} {
		if got := logLevelName(level); got != expected {
			t.Fatalf("logLevelName(%d) = %q, want %q", level, got, expected)
		}
	}
}
