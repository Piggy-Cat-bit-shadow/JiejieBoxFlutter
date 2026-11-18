package main

// runRuntimeSelfTest is the non-privileged real-process integration the contract asks
// for: it starts a real Box with a provider and a selector, then drives the runtime
// bridge the way the Dart app does — subscribe, refresh, select, read the mode list,
// clear logs, close connections, stop — and checks the answers against real state.
//
// It runs inside the linked host binary (`core_host_libbox.exe --selftest`), uses no
// test hook, needs no TUN and never touches the public network: the provider is a
// loopback HTTP server this function starts and stops itself.

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

func runRuntimeSelfTest(server *hostServer, expect func(bool, string) error) error {
	// --- a loopback provider document -------------------------------------------
	listener, listenErr := net.Listen("tcp", "127.0.0.1:0")
	if listenErr != nil {
		return listenErr
	}
	providerURL := "http://" + listener.Addr().String() + "/nodes"
	httpServer := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"outbounds":[{"type":"socks","tag":"node-a","server":"127.0.0.1","server_port":9}]}`))
	})}
	go func() { _ = httpServer.Serve(listener) }()
	defer func() { _ = httpServer.Close() }()

	config := fmt.Sprintf(`{
      "log": {"level": "warn"},
      "providers": [{"type": "remote", "tag": "local-p", "url": %q, "update_interval": "1h"}],
      "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "providers": ["local-p"]}
      ],
      "route": {"final": "direct"}
    }`, providerURL)

	write := server.Handle(request{ID: "rt-write", Method: "profile.write", Args: map[string]any{
		"label": "runtime-selftest", "kind": "local", "content": encodeBase64([]byte(config)),
	}})
	if err := expect(write.OK, "runtime selftest: profile.write must succeed"); err != nil {
		return err
	}
	meta, _ := write.Result.(map[string]any)
	profileID, _ := meta["id"].(string)
	profileRevision, _ := meta["revision"].(string)
	revision := server.sm.revision + 10

	start := server.Handle(request{ID: "rt-start", Method: "service.start", Args: map[string]any{
		"profileId": profileID, "profileRevision": profileRevision, "revision": float64(revision), "mode": "proxy",
	}})
	if err := expect(start.OK, "runtime selftest: service.start must succeed: "+describeResponse(start)); err != nil {
		return err
	}

	// --- provider refresh through the real CommandClient ------------------------
	// The first refresh after a start can answer "skipped": the Box is still bringing
	// its provider set up, and the kernel's own timer may hold it. A real client must
	// retry rather than treat that as a failure, so the test does the same and then
	// asserts on the settled answer.
	var refreshResult map[string]any
	deadline := time.Now().Add(10 * time.Second)
	for {
		refresh := server.Handle(request{ID: "rt-refresh", Method: "provider.refresh", Args: map[string]any{
			"tags": []any{"local-p"}, "timeoutMillis": float64(5000),
		}})
		if err := expect(refresh.OK, "runtime selftest: provider.refresh must succeed: "+describeResponse(refresh)); err != nil {
			return err
		}
		refreshResult, _ = refresh.Result.(map[string]any)
		if supported, _ := refreshResult["supported"].(bool); !supported {
			return expect(false, "runtime selftest: a linked kernel must report provider refresh as supported")
		}
		results := anySlice(refreshResult["results"])
		if len(results) == 1 {
			if first, _ := results[0].(map[string]any); first != nil {
				if first["status"] == "published" || first["status"] == "unchanged" {
					if err := expect(first["tag"] == "local-p", "runtime selftest: the result must name the provider"); err != nil {
						return err
					}
					break
				}
			}
		}
		if time.Now().After(deadline) {
			return expect(false, "runtime selftest: the provider never published, last status "+describeRefresh(refreshResult))
		}
		time.Sleep(100 * time.Millisecond)
	}

	// --- subscription: wait for the first groups snapshot ------------------------
	// The stream can deliver an empty snapshot before the Box has registered its
	// groups, so the wait is for a NON-EMPTY one. This is real behaviour the Dart
	// consumer must also tolerate: an empty first frame is not "no groups".
	groupsPayload := waitForGroups(server, 8*time.Second)
	if err := expect(groupsPayload != nil, "runtime selftest: a runtime.groups event must arrive"); err != nil {
		return err
	}
	groups := anySlice(groupsPayload["groups"])
	if err := expect(len(groups) > 0, "runtime selftest: groups must not be empty"); err != nil {
		return err
	}
	foundProxy := false
	for _, entry := range groups {
		group, _ := entry.(map[string]any)
		if group["tag"] == "proxy" {
			foundProxy = true
			members := anySlice(group["items"])
			if err := expect(len(members) >= 1, "runtime selftest: the proxy group must report its members"); err != nil {
				return err
			}
		}
	}
	if err := expect(foundProxy, "runtime selftest: the selector group must be reported"); err != nil {
		return err
	}

	// --- selection: read back the applied member --------------------------------
	selectResponse := server.Handle(request{ID: "rt-select", Method: "group.select", Args: map[string]any{
		"group": "proxy", "outbound": "local-p/node-a", "requestId": "77", "expectedRevision": float64(0),
	}})
	if err := expect(selectResponse.OK, "runtime selftest: group.select must succeed: "+describeResponse(selectResponse)); err != nil {
		return err
	}
	selectResult, _ := selectResponse.Result.(map[string]any)
	if err := expect(selectResult["accepted"] == true, "runtime selftest: selection must be accepted"); err != nil {
		return err
	}
	if err := expect(selectResult["appliedOutbound"] == "local-p/node-a",
		"runtime selftest: the write must be read back, got "+fmt.Sprint(selectResult["appliedOutbound"])); err != nil {
		return err
	}

	// --- modes: this profile declares no clash_mode, so the list must be empty ---
	modeStatus := server.Handle(request{ID: "rt-mode", Method: "mode.status"})
	if err := expect(modeStatus.OK, "runtime selftest: mode.status must answer"); err != nil {
		return err
	}
	modeResult, _ := modeStatus.Result.(map[string]any)
	modes := anySlice(modeResult["modes"])
	if len(modes) > 0 {
		// The kernel owns the list: whatever it reports must be switchable, and a mode
		// outside the list must be refused. That is the only honest pair of assertions.
		first, _ := modes[0].(string)
		setMode := server.Handle(request{ID: "rt-mode-set", Method: "mode.set", Args: map[string]any{"mode": first}})
		if err := expect(setMode.OK, "runtime selftest: switching to a reported mode must succeed: "+describeResponse(setMode)); err != nil {
			return err
		}
		rejected := server.Handle(request{ID: "rt-mode-bad", Method: "mode.set", Args: map[string]any{"mode": "not-a-mode"}})
		if err := expect(!rejected.OK && rejected.Error.Code == "mode_not_available",
			"runtime selftest: an unreported mode must be refused"); err != nil {
			return err
		}
	}

	// --- logs: the clear command answers and emits its signal -------------------
	clear := server.Handle(request{ID: "rt-logs", Method: "logs.clear"})
	if err := expect(clear.OK, "runtime selftest: logs.clear must answer"); err != nil {
		return err
	}
	if err := expect(waitForEvent(server, eventLogsCleared, 2*time.Second) != nil,
		"runtime selftest: logs.cleared must be emitted"); err != nil {
		return err
	}

	// --- connections: the close-all command must reach the client ---------------
	closeAll := server.Handle(request{ID: "rt-conns", Method: "connections.closeAll"})
	if err := expect(closeAll.OK, "runtime selftest: connections.closeAll must answer: "+describeResponse(closeAll)); err != nil {
		return err
	}

	// --- stop, and the runtime surface must go honestly unavailable -------------
	stop := server.Handle(request{ID: "rt-stop", Method: "service.stop", Args: map[string]any{
		"revision": float64(revision + 1),
	}})
	if err := expect(stop.OK, "runtime selftest: service.stop must succeed"); err != nil {
		return err
	}
	afterStop := server.Handle(request{ID: "rt-after", Method: "group.select", Args: map[string]any{
		"group": "proxy", "outbound": "direct", "requestId": "78",
	}})
	if err := expect(!afterStop.OK && afterStop.Error.Code == "unsupported_platform",
		"runtime selftest: commands must be unsupported once the service is stopped"); err != nil {
		return err
	}
	return nil
}

// waitForGroups drains the queue until a groups frame carrying at least one group
// arrives. An empty frame is skipped because it precedes the Box's registry.
func waitForGroups(server *hostServer, timeout time.Duration) map[string]any {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		payload := waitForEvent(server, eventRuntimeGroups, time.Until(deadline))
		if payload == nil {
			return nil
		}
		groups := anySlice(payload["groups"])
		if len(groups) > 0 {
			return payload
		}
	}
	return nil
}

// waitForEvent drains the event queue until one of the wanted type appears.
func waitForEvent(server *hostServer, kind string, timeout time.Duration) map[string]any {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		event := server.popEvent()
		if event == nil {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		if os.Getenv("JJ_RT_DEBUG") != "" {
			summary := ""
			if data, ok := event["data"].(map[string]any); ok {
				if groups := anySlice(data["groups"]); groups != nil {
					summary = fmt.Sprintf(" groups=%d", len(groups))
				}
				if entries, ok := data["entries"].([]any); ok {
					summary = fmt.Sprintf(" logs=%d", len(entries))
				}
			}
			fmt.Fprintf(os.Stderr, "[rt] event type=%v%s\n", event["type"], summary)
		}
		if event["type"] == kind {
			data, _ := event["data"].(map[string]any)
			return data
		}
	}
	return nil
}

func lenPayload(event map[string]any) int {
	if data, ok := event["data"].(map[string]any); ok {
		return len(data)
	}
	return 0
}

// describeResponse renders a failed response without dumping the whole document.
func describeResponse(response response) string {
	if response.OK {
		return "ok"
	}
	if response.Error == nil {
		return "failed without an error"
	}
	return response.Error.Code + ": " + response.Error.Message
}

// anySlice tolerates the two shapes a list can have in-process: the event payload is
// built from typed Go slices ([]map[string]any) while JSON-decoded values arrive as
// []any. A test that asserts on both paths must not care which one it got.
func anySlice(value any) []any {
	switch typed := value.(type) {
	case []any:
		return typed
	case []map[string]any:
		out := make([]any, len(typed))
		for index, entry := range typed {
			out[index] = entry
		}
		return out
	case nil:
		return nil
	default:
		return nil
	}
}

// describeRefresh renders the last refresh answer for a failure message.
func describeRefresh(result map[string]any) string {
	if result == nil {
		return "<nil>"
	}
	return fmt.Sprint(result["results"])
}
