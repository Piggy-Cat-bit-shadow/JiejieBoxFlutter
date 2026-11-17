package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"sync"
)

// coreAPI is the single seam the shell has towards libbox. The default build has
// no linkable artifact, so it answers core_unavailable; a `libbox` build swaps in
// the adapter without touching the dispatcher.
type coreAPI interface {
	Capabilities() map[string]any
	CheckConfig(content string) (map[string]any, *bridgeError)
	FormatConfig(content string) (map[string]any, *bridgeError)
	Preview(content string) (map[string]any, *bridgeError)
	Refresh(tags []string, timeoutMillis int64) (map[string]any, *bridgeError)
}

type hostServer struct {
	sm      *stateMachine
	store   *profileStore
	core    coreAPI
	seq     int64
	eventMu sync.Mutex
	pending []map[string]any
	hooks   bool
}

func newHostServer(store *profileStore, core coreAPI) *hostServer {
	return &hostServer{
		sm:    newStateMachine(false),
		store: store,
		core:  core,
	}
}

// emit queues an event frame for the connection that caused it. The host has one
// client today (the app), so per-connection delivery is enough; a broadcast hub is
// a P4 concern once the tray or a second window can connect.
func (s *hostServer) emit(kind string, data map[string]any) {
	s.eventMu.Lock()
	defer s.eventMu.Unlock()
	s.seq++
	s.pending = append(s.pending, map[string]any{
		"type": kind,
		"seq":  s.seq,
		"data": data,
	})
}

func (s *hostServer) takeEvents() []map[string]any {
	s.eventMu.Lock()
	defer s.eventMu.Unlock()
	out := s.pending
	s.pending = nil
	return out
}

func (s *hostServer) Handle(req request) response {
	switch req.Method {
	case "host.capabilities":
		return ok(req.ID, map[string]any{
			// core tells the app whether config.* can ever succeed in this build.
			"core":        coreLinked,
			"tun":         false,
			"systemProxy": true,
			"perAppProxy": false,
			"autostart":   true,
			"tray":        true,
			"qrCamera":    false,
			// No QR image decoder ships with the Windows host yet; claiming it would
			// light up a dead UI entry (P4 QR strategy).
			"qrImageDecode":  false,
			"fileImport":     true,
			"clipboardWatch": true,
			"notifications":  true,
			"deepLink":       true,
			"memoryPressure": false,
			"serviceModes":   []string{"proxy"},
		})
	case "core.capabilities":
		return ok(req.ID, s.core.Capabilities())
	case "host.setup":
		return ok(req.ID, map[string]any{})
	case "host.shutdown":
		s.sm.close(s.sm.revision + 1)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{})
	case "test.runtime":
		if !s.hooks {
			return fail(req.ID, errUnsupportedPlatform("test hooks"))
		}
		s.sm.runtimeReport(argBool(req.Args, "running", false), 0)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{"state": s.sm.state})
	case "test.permission":
		if !s.hooks {
			return fail(req.ID, errUnsupportedPlatform("test hooks"))
		}
		s.sm.permissionReport(argBool(req.Args, "granted", false))
		s.emit("permission.changed", map[string]any{"kind": "vpn", "status": s.sm.state})
		return ok(req.ID, map[string]any{"state": s.sm.state})
	case "service.start":
		revision := argInt(req.Args, "revision")
		mode := argString(req.Args, "mode")
		outcome := s.sm.start(revision, mode == "vpn")
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{
			"accepted": outcome != "rejected:closed",
			"revision": revision,
		})
	case "service.stop":
		revision := argInt(req.Args, "revision")
		outcome := s.sm.stop(revision)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{
			"accepted": outcome != "rejected:closed",
			"revision": revision,
		})
	case "service.status":
		return ok(req.ID, s.status())
	case "config.check":
		content, contentErr := argContent(req.Args)
		if contentErr != nil {
			return fail(req.ID, contentErr)
		}
		result, err := s.core.CheckConfig(content)
		if err != nil {
			return fail(req.ID, err)
		}
		return ok(req.ID, result)
	case "config.format":
		result, err := s.core.FormatConfig(argString(req.Args, "content"))
		if err != nil {
			return fail(req.ID, err)
		}
		return ok(req.ID, result)
	case "config.preview":
		result, err := s.core.Preview(argString(req.Args, "content"))
		if err != nil {
			return fail(req.ID, err)
		}
		return ok(req.ID, result)
	case "profile.list":
		metas, err := s.store.List()
		if err != nil {
			return fail(req.ID, errStorageWriteFailed("list profiles"))
		}
		items := make([]map[string]any, 0, len(metas))
		for _, meta := range metas {
			items = append(items, map[string]any{
				"id":              meta.ID,
				"label":           meta.Label,
				"kind":            meta.Kind,
				"revision":        meta.Revision,
				"updatedAtMillis": meta.UpdatedAtMillis,
				"source":          "local",
			})
		}
		return ok(req.ID, map[string]any{"items": items})
	case "profile.read":
		meta, body, err := s.store.Read(argString(req.Args, "id"))
		if err != nil {
			if bridge, isBridge := err.(*bridgeError); isBridge {
				return fail(req.ID, bridge)
			}
			return fail(req.ID, errInvalidArgument("no such profile"))
		}
		return ok(req.ID, map[string]any{
			"id":              meta.ID,
			"content":         encodeBase64(body),
			"revision":        meta.Revision,
			"updatedAtMillis": meta.UpdatedAtMillis,
		})
	case "profile.write":
		var expected *string
		if value := argString(req.Args, "expectedRevision"); value != "" {
			expected = &value
		}
		body, decodeErr := decodeBase64(argString(req.Args, "content"))
		if decodeErr != nil {
			return fail(req.ID, errInvalidArgument("content must be base64"))
		}
		meta, err := s.store.Write(
			argString(req.Args, "id"),
			argString(req.Args, "label"),
			argString(req.Args, "kind"),
			body,
			expected,
			argBool(req.Args, "validate", true),
		)
		if err != nil {
			if bridge, isBridge := err.(*bridgeError); isBridge {
				return fail(req.ID, bridge)
			}
			return fail(req.ID, errStorageWriteFailed("write profile"))
		}
		return ok(req.ID, map[string]any{
			"id":        meta.ID,
			"revision":  meta.Revision,
			"bytes":     len(body),
			"validated": argBool(req.Args, "validate", true),
		})
	case "profile.delete":
		var expected *string
		if value := argString(req.Args, "expectedRevision"); value != "" {
			expected = &value
		}
		if err := s.store.Delete(argString(req.Args, "id"), expected); err != nil {
			if bridge, isBridge := err.(*bridgeError); isBridge {
				return fail(req.ID, bridge)
			}
			return fail(req.ID, errStorageWriteFailed("delete profile"))
		}
		return ok(req.ID, map[string]any{})
	case "profile.restore":
		meta, err := s.store.Restore(
			argString(req.Args, "id"),
			argString(req.Args, "revision"),
		)
		if err != nil {
			if bridge, isBridge := err.(*bridgeError); isBridge {
				return fail(req.ID, bridge)
			}
			return fail(req.ID, errStorageWriteFailed("restore profile"))
		}
		return ok(req.ID, map[string]any{
			"id":        meta.ID,
			"revision":  meta.Revision,
			"validated": true,
		})
	case "profile.apply":
		revision := argInt(req.Args, "revision")
		outcome := s.sm.start(revision, true)
		return ok(req.ID, map[string]any{
			"applied":   outcome != "rejected:closed",
			"requestId": argString(req.Args, "requestId"),
		})
	case "provider.refresh":
		tags := []string{}
		if raw, found := req.Args["tags"].([]any); found {
			for _, entry := range raw {
				if tag, isString := entry.(string); isString {
					tags = append(tags, tag)
				}
			}
		}
		result, err := s.core.Refresh(tags, argInt(req.Args, "timeoutMillis"))
		if err != nil {
			return fail(req.ID, err)
		}
		return ok(req.ID, result)
	case "systemProxy.apply", "systemProxy.status", "app.setAutoLaunch", "tray.update":
		// The C++ plugin owns the WinINet and shell side; this process answers the
		// shape so the Dart contract can be exercised end to end.
		return ok(req.ID, map[string]any{"ourProxyActive": false, "enabled": argBool(req.Args, "enabled", false), "applied": false})
	case "tun.requestPermission":
		return fail(req.ID, errUnsupportedPlatform("TUN"))
	case "qr.scan", "file.pickConfig", "clipboard.readCandidate":
		return fail(req.ID, errUnsupportedPlatform("activity-scoped input"))
	default:
		return fail(req.ID, &bridgeError{
			Code:      "unsupported_platform",
			Message:   "unknown method " + req.Method,
			Retryable: false,
		})
	}
}

func (s *hostServer) status() map[string]any {
	return map[string]any{
		"state":       s.sm.state,
		"revision":    s.sm.revision,
		"sinceMillis": s.sm.revision,
		"mode":        "proxy",
		"tunActive":   s.sm.running,
		"proxyPort":   7890,
		"permission":  "granted",
	}
}

// Serve reads one JSON request per line and writes one JSON response per line.
// Loopback only: the P2 step is a named pipe with an ACL, not a wider bind.
func (s *hostServer) Serve(listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go s.serveConn(conn)
	}
}

func (s *hostServer) serveConn(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	writer := bufio.NewWriter(conn)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var req request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			encoded, _ := json.Marshal(fail("", errInvalidArgument("malformed request")))
			writer.Write(encoded)
			writer.WriteString("\n")
			writer.Flush()
			continue
		}
		encoded, _ := json.Marshal(s.Handle(req))
		writer.Write(encoded)
		writer.WriteString("\n")
		for _, event := range s.takeEvents() {
			frame, _ := json.Marshal(event)
			writer.Write(frame)
			writer.WriteString("\n")
		}
		if err := writer.Flush(); err != nil {
			return
		}
	}
}
