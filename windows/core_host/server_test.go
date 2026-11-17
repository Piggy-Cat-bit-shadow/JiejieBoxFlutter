package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validProxy = `{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`

func newTestServer(t *testing.T) *hostServer {
	t.Helper()
	dir := t.TempDir()
	store, err := newProfileStore(dir)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	return newHostServer(store, unlinkedCore{})
}

func newFakeServer(t *testing.T) (*hostServer, *fakeCore) {
	t.Helper()
	dir := t.TempDir()
	store, err := newProfileStore(dir)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	core := &fakeCore{}
	return newHostServer(store, core), core
}

func writeProfile(t *testing.T, server *hostServer, content string) (string, string) {
	t.Helper()
	write := server.Handle(request{ID: "w", Method: "profile.write", Args: map[string]any{
		"label": "test", "kind": "local", "content": encodeBase64([]byte(content)),
	}})
	if !write.OK {
		t.Fatalf("profile.write: %+v", write.Error)
	}
	result := write.Result.(map[string]any)
	return result["id"].(string), result["revision"].(string)
}

func startProfile(server *hostServer, revision int64, id, profileRevision string) response {
	return server.Handle(request{ID: "start", Method: "service.start", Args: map[string]any{
		"revision":        float64(revision),
		"mode":            "proxy",
		"profileId":       id,
		"profileRevision": profileRevision,
	}})
}

func TestCapabilitiesDoNotClaimDeadWindowsFeatures(t *testing.T) {
	server := newTestServer(t)
	response := server.Handle(request{ID: "1", Method: "host.capabilities"})
	if !response.OK {
		t.Fatalf("capabilities: %+v", response.Error)
	}
	caps := response.Result.(map[string]any)
	for _, key := range []string{"systemProxy", "autostart", "tray", "notifications", "deepLink", "events", "tun"} {
		if caps[key] != false {
			t.Errorf("%s must be false until implemented, got %v", key, caps[key])
		}
	}
	modes, _ := caps["serviceModes"].([]string)
	if len(modes) != 1 || modes[0] != "proxy" {
		t.Errorf("serviceModes = %v", caps["serviceModes"])
	}
}

func TestStartWithoutProfileFails(t *testing.T) {
	server, core := newFakeServer(t)
	response := server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{
		"revision": float64(1), "mode": "proxy",
	}})
	if response.OK || response.Error.Code != "profile_not_found" {
		t.Fatalf("expected profile_not_found, got %+v", response)
	}
	if len(core.started) != 0 {
		t.Fatalf("core started without a profile: %v", core.started)
	}
}

func TestStartRequiresExistingProfileAndMatchingRevision(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	missing := startProfile(server, 1, "DOES_NOT_EXIST", revision)
	if missing.OK || missing.Error.Code != "profile_not_found" {
		t.Fatalf("missing profile: %+v", missing)
	}
	stale := startProfile(server, 1, id, "not-the-revision")
	if stale.OK || stale.Error.Code != "revision_mismatch" {
		t.Fatalf("stale profile revision: %+v", stale)
	}
	if len(core.started) != 0 {
		t.Fatalf("core started despite invalid profile: %v", core.started)
	}
}

func TestStartCallsCoreAndStatusIsRunning(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	response := startProfile(server, 1, id, revision)
	if !response.OK {
		t.Fatalf("start: %+v", response.Error)
	}
	if !core.Running() || len(core.started) != 1 || core.started[0] != validProxy {
		t.Fatalf("core did not receive the profile document: running=%v started=%v", core.Running(), core.started)
	}
	status := server.Handle(request{ID: "2", Method: "service.status"})
	state, _ := status.Result.(map[string]any)["state"].(string)
	if state != stateRunning {
		t.Fatalf("status state = %s", state)
	}
	if server.active.id != id || server.active.revision != revision {
		t.Fatalf("active profile not recorded: %+v", server.active)
	}
}

func TestDuplicateRevisionFailsAndDoesNotRestart(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 5, id, revision); !response.OK {
		t.Fatalf("first start: %+v", response.Error)
	}
	duplicate := startProfile(server, 5, id, revision)
	if duplicate.OK || duplicate.Error.Code != "stale_revision" {
		t.Fatalf("duplicate revision must fail, got %+v", duplicate)
	}
	older := startProfile(server, 4, id, revision)
	if older.OK || older.Error.Code != "stale_revision" {
		t.Fatalf("older revision must fail, got %+v", older)
	}
	if len(core.started) != 1 {
		t.Fatalf("stale requests restarted the core: %v", core.started)
	}
}

func TestStopCallsCoreAndSettlesIdle(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 1, id, revision); !response.OK {
		t.Fatalf("start: %+v", response.Error)
	}
	stop := server.Handle(request{ID: "2", Method: "service.stop", Args: map[string]any{"revision": float64(2)}})
	if !stop.OK {
		t.Fatalf("stop: %+v", stop.Error)
	}
	if core.Running() || core.stopCall != 1 {
		t.Fatalf("core not stopped: running=%v stopCall=%d", core.Running(), core.stopCall)
	}
	status := server.Handle(request{ID: "3", Method: "service.status"})
	state, _ := status.Result.(map[string]any)["state"].(string)
	if state != stateIdle {
		t.Fatalf("status state = %s", state)
	}
}

func TestVpnModeRejectedOnWindows(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	response := server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{
		"revision": float64(1), "mode": "vpn", "profileId": id, "profileRevision": revision,
	}})
	if response.OK || response.Error.Code != "unsupported_platform" {
		t.Fatalf("vpn must be unsupported, got %+v", response)
	}
	if len(core.started) != 0 {
		t.Fatal("vpn mode reached the core")
	}
}

func TestProfileApplyMissingProfileFails(t *testing.T) {
	server, core := newFakeServer(t)
	response := server.Handle(request{ID: "1", Method: "profile.apply", Args: map[string]any{
		"id": "DOES_NOT_EXIST", "revision": "r1", "requestId": "req-1", "mode": "proxy",
	}})
	if response.OK || response.Error.Code != "profile_not_found" {
		t.Fatalf("expected profile_not_found, got %+v", response)
	}
	if len(core.started) != 0 {
		t.Fatal("missing profile reached the core")
	}
}

func TestProfileApplyStaleRevisionFails(t *testing.T) {
	server, core := newFakeServer(t)
	id, _ := writeProfile(t, server, validProxy)
	response := server.Handle(request{ID: "1", Method: "profile.apply", Args: map[string]any{
		"id": id, "revision": "old-revision", "requestId": "req-1", "mode": "proxy",
	}})
	if response.OK || response.Error.Code != "revision_mismatch" {
		t.Fatalf("expected revision_mismatch, got %+v", response)
	}
	if len(core.started) != 0 {
		t.Fatal("stale profile apply reached the core")
	}
}

func TestProfileApplyStartsAndSwitches(t *testing.T) {
	server, core := newFakeServer(t)
	firstID, firstRevision := writeProfile(t, server, validProxy)
	second := `{"log":{"level":"warn"}}`
	secondID, secondRevision := writeProfile(t, server, second)

	if response := startProfile(server, 1, firstID, firstRevision); !response.OK {
		t.Fatalf("start first: %+v", response.Error)
	}
	apply := server.Handle(request{ID: "2", Method: "profile.apply", Args: map[string]any{
		"id": secondID, "revision": secondRevision, "requestId": "req-2", "mode": "proxy",
	}})
	if !apply.OK {
		t.Fatalf("apply second: %+v", apply.Error)
	}
	if server.active.id != secondID {
		t.Fatalf("active profile = %+v", server.active)
	}
	if len(core.started) != 2 || core.started[1] != second {
		t.Fatalf("core did not receive the new document: %v", core.started)
	}
	report := apply.Result.(map[string]any)
	if report["applied"] != true || report["requestId"] != "req-2" {
		t.Fatalf("apply report = %+v", report)
	}
}

func TestProfileApplyInvalidConfigDoesNotSwitch(t *testing.T) {
	server, core := newFakeServer(t)
	goodID, goodRevision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 1, goodID, goodRevision); !response.OK {
		t.Fatalf("start good: %+v", response.Error)
	}
	badID, badRevision := writeProfile(t, server, `{"invalid":true}`)
	apply := server.Handle(request{ID: "2", Method: "profile.apply", Args: map[string]any{
		"id": badID, "revision": badRevision, "requestId": "req-bad", "mode": "proxy",
	}})
	if apply.OK || apply.Error.Code != "core_rejected_config" {
		t.Fatalf("invalid config must fail, got %+v", apply)
	}
	if server.active.id != goodID {
		t.Fatalf("active profile moved to invalid document: %+v", server.active)
	}
	if len(core.started) != 1 {
		t.Fatalf("invalid document reached the core: %v", core.started)
	}
}

func TestProfileApplyFailureRollsBackLastGood(t *testing.T) {
	server, core := newFakeServer(t)
	goodID, goodRevision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 1, goodID, goodRevision); !response.OK {
		t.Fatalf("start good: %+v", response.Error)
	}
	core.startErr = func(content string) *bridgeError {
		if strings.Contains(content, "boom") {
			return &bridgeError{Code: "core_start_failed", Message: "test reload rejected", Retryable: true}
		}
		return nil
	}
	boomID, boomRevision := writeProfile(t, server, `{"boom":true}`)
	apply := server.Handle(request{ID: "2", Method: "profile.apply", Args: map[string]any{
		"id": boomID, "revision": boomRevision, "requestId": "req-boom", "mode": "proxy",
	}})
	if apply.OK || apply.Error == nil || apply.Error.Code != "core_start_failed" {
		t.Fatalf("expected core_start_failed, got %+v", apply)
	}
	if apply.Error.Details["rolledBack"] != true {
		t.Fatalf("missing rollback evidence: %+v", apply.Error.Details)
	}
	if len(core.started) != 2 || core.started[1] != validProxy {
		t.Fatalf("old document was not re-applied: %v", core.started)
	}
	if !core.Running() {
		t.Fatal("core must still be running after rollback")
	}
	if server.active.id != goodID {
		t.Fatalf("active profile changed after failed apply: %+v", server.active)
	}
}

func TestSystemIntegrationIsDisabled(t *testing.T) {
	server := newTestServer(t)
	for _, method := range []string{"systemProxy.apply", "systemProxy.status", "app.setAutoLaunch", "tray.update"} {
		response := server.Handle(request{ID: method, Method: method})
		if response.OK || response.Error.Code != "unsupported_platform" {
			t.Errorf("%s must be unsupported, got %+v", method, response)
		}
	}
}

func TestShutdownStopsCore(t *testing.T) {
	server, core := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 1, id, revision); !response.OK {
		t.Fatalf("start: %+v", response.Error)
	}
	shutdown := server.Handle(request{ID: "2", Method: "host.shutdown"})
	if !shutdown.OK {
		t.Fatalf("shutdown: %+v", shutdown.Error)
	}
	if core.Running() {
		t.Fatal("shutdown left the core running")
	}
	if server.sm.state != stateClosed {
		t.Fatalf("state = %s", server.sm.state)
	}
}

func TestStoreWritesAtomicallyAndChecksRevision(t *testing.T) {
	server := newTestServer(t)
	write := server.Handle(request{ID: "1", Method: "profile.write", Args: map[string]any{
		"label":   "a",
		"kind":    "local",
		"content": encodeBase64([]byte("{}")),
	}})
	if !write.OK {
		t.Fatalf("write failed: %+v", write.Error)
	}
	meta := write.Result.(map[string]any)
	id := meta["id"].(string)
	revision := meta["revision"].(string)

	stale := server.Handle(request{ID: "2", Method: "profile.write", Args: map[string]any{
		"id":               id,
		"label":            "a",
		"kind":             "local",
		"content":          encodeBase64([]byte("{}")),
		"expectedRevision": "not-the-revision",
	}})
	if stale.OK || stale.Error == nil || stale.Error.Code != "revision_mismatch" {
		t.Fatalf("expected revision_mismatch, got %+v", stale)
	}

	fresh := server.Handle(request{ID: "3", Method: "profile.write", Args: map[string]any{
		"id":               id,
		"label":            "a",
		"kind":             "local",
		"content":          encodeBase64([]byte(`{"x":1}`)),
		"expectedRevision": revision,
	}})
	if !fresh.OK {
		t.Fatalf("matching revision rejected: %+v", fresh.Error)
	}
	read := server.Handle(request{ID: "4", Method: "profile.read", Args: map[string]any{"id": id}})
	body, _ := decodeBase64(read.Result.(map[string]any)["content"].(string))
	if string(body) != `{"x":1}` {
		t.Fatalf("body not updated: %q", body)
	}
}

func TestUnknownMethodAnswersUnsupportedPlatform(t *testing.T) {
	server := newTestServer(t)
	response := server.Handle(request{ID: "1", Method: "nope.nothing"})
	if response.OK || response.Error.Code != "unsupported_platform" {
		t.Fatalf("got %+v", response)
	}
}

func TestEventsAreQueuedForTheCaller(t *testing.T) {
	server, _ := newFakeServer(t)
	id, revision := writeProfile(t, server, validProxy)
	if response := startProfile(server, 1, id, revision); !response.OK {
		t.Fatalf("start: %+v", response.Error)
	}
	events := server.takeEvents()
	if len(events) == 0 {
		t.Fatal("start should emit a state event")
	}
	if events[0]["type"] != "service.state" {
		t.Fatalf("unexpected event %+v", events[0])
	}
	if server.takeEvents() != nil {
		t.Fatal("events must be drained once")
	}
}

func TestTestHooksAreOffByDefault(t *testing.T) {
	server := newTestServer(t)
	response := server.Handle(request{ID: "1", Method: "test.runtime", Args: map[string]any{"running": true}})
	if response.OK || response.Error.Code != "unsupported_platform" {
		t.Fatalf("hooks must be off by default: %+v", response)
	}
}

func TestSelfTestPasses(t *testing.T) {
	if err := runSelfTest(newTestServer(t)); err != nil {
		t.Fatalf("selftest: %v", err)
	}
}

func TestServeRoundTrip(t *testing.T) {
	server := newTestServer(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = server.Serve(listener) }()
	defer listener.Close()

	connection, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer connection.Close()
	if _, err = connection.Write([]byte("{\"id\":\"1\",\"method\":\"host.capabilities\"}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buffer := make([]byte, 4096)
	count, err := connection.Read(buffer)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(buffer[:count]), "\"ok\":true") {
		t.Fatalf("unexpected response: %s", string(buffer[:count]))
	}
}

func TestRestoreSwapsBackThePreviousRevision(t *testing.T) {
	server := newTestServer(t)
	first := server.Handle(request{ID: "1", Method: "profile.write", Args: map[string]any{
		"label": "a", "kind": "local", "content": encodeBase64([]byte(`{"v":1}`)),
	}})
	if !first.OK {
		t.Fatalf("first write: %+v", first.Error)
	}
	firstMeta := first.Result.(map[string]any)
	second := server.Handle(request{ID: "2", Method: "profile.write", Args: map[string]any{
		"id": firstMeta["id"], "label": "a", "kind": "local",
		"content": encodeBase64([]byte(`{"v":2}`)), "expectedRevision": firstMeta["revision"],
	}})
	if !second.OK {
		t.Fatalf("second write: %+v", second.Error)
	}
	restore := server.Handle(request{ID: "3", Method: "profile.restore", Args: map[string]any{
		"id": firstMeta["id"], "revision": firstMeta["revision"],
	}})
	if !restore.OK {
		t.Fatalf("restore: %+v", restore.Error)
	}
	read := server.Handle(request{ID: "4", Method: "profile.read", Args: map[string]any{"id": firstMeta["id"]}})
	body, _ := decodeBase64(read.Result.(map[string]any)["content"].(string))
	if string(body) != `{"v":1}` {
		t.Fatalf("restored body: %q", body)
	}
}

func TestRestoreUnknownRevisionIsMismatch(t *testing.T) {
	server := newTestServer(t)
	write := server.Handle(request{ID: "1", Method: "profile.write", Args: map[string]any{
		"label": "a", "kind": "local", "content": encodeBase64([]byte(`{}`)),
	}})
	id := write.Result.(map[string]any)["id"].(string)
	restore := server.Handle(request{ID: "2", Method: "profile.restore", Args: map[string]any{
		"id": id, "revision": "deadbeef",
	}})
	if restore.OK || restore.Error.Code != "revision_mismatch" {
		t.Fatalf("got %+v", restore)
	}
}

func TestCorruptMetaAnswersStorageCorrupt(t *testing.T) {
	dir := t.TempDir()
	store, err := newProfileStore(dir)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	server := newHostServer(store, unlinkedCore{})
	write := server.Handle(request{ID: "1", Method: "profile.write", Args: map[string]any{
		"label": "a", "kind": "local", "content": encodeBase64([]byte(`{}`)),
	}})
	id := write.Result.(map[string]any)["id"].(string)
	if err = os.WriteFile(filepath.Join(dir, id+".meta.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatalf("corrupt: %v", err)
	}
	read := server.Handle(request{ID: "2", Method: "profile.read", Args: map[string]any{"id": id}})
	if read.OK || read.Error.Code != "storage_corrupt" {
		t.Fatalf("got %+v", read)
	}
}
