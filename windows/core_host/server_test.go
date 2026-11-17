package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *hostServer {
	t.Helper()
	dir := t.TempDir()
	store, err := newProfileStore(dir)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	return newHostServer(store, unlinkedCore{})
}

func TestStartAckIsNotRunning(t *testing.T) {
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(1), "mode": "proxy"}})
	if server.sm.state == stateRunning {
		t.Fatal("an ack must not produce running")
	}
	if server.sm.state != stateStarting {
		t.Fatalf("expected starting, got %s", server.sm.state)
	}
}

func TestRuntimeEvidenceMakesRunning(t *testing.T) {
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(1)}})
	if outcome := server.sm.runtimeReport(true, 0); outcome != "applied" {
		t.Fatalf("expected applied, got %s", outcome)
	}
	if server.sm.state != stateRunning {
		t.Fatalf("expected running, got %s", server.sm.state)
	}
}

func TestStaleRevisionIsRejected(t *testing.T) {
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(5)}})
	response := server.Handle(request{ID: "2", Method: "service.stop", Args: map[string]any{"revision": float64(4)}})
	if !response.OK || len(server.sm.errors) == 0 || server.sm.errors[len(server.sm.errors)-1] != "stale_revision" {
		t.Fatalf("expected stale_revision, errors=%v", server.sm.errors)
	}
	if server.sm.revision != 5 {
		t.Fatalf("revision moved to %d", server.sm.revision)
	}
}

func TestCloseIsTerminal(t *testing.T) {
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(1)}})
	server.sm.runtimeReport(true, 0)
	server.Handle(request{ID: "2", Method: "host.shutdown"})
	server.sm.runtimeReport(false, 0)
	if server.sm.state != stateClosed {
		t.Fatalf("expected closed, got %s", server.sm.state)
	}
	server.Handle(request{ID: "3", Method: "service.start", Args: map[string]any{"revision": float64(9)}})
	if server.sm.state != stateClosed {
		t.Fatalf("closed machine moved to %s", server.sm.state)
	}
}

func TestPermissionDenialFailsStart(t *testing.T) {
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(1), "mode": "vpn"}})
	if server.sm.state != stateAwaitingPermission {
		t.Fatalf("expected awaitingPermission, got %s", server.sm.state)
	}
	if outcome := server.sm.permissionReport(false); outcome != "failed" {
		t.Fatalf("expected failed, got %s", outcome)
	}
	if server.sm.state != stateFailed {
		t.Fatalf("expected failed state, got %s", server.sm.state)
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
	server := newTestServer(t)
	server.Handle(request{ID: "1", Method: "service.start", Args: map[string]any{"revision": float64(1)}})
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
