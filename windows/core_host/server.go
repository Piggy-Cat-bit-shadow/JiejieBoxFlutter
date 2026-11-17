package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"sync"
	"time"
)

// coreAPI is the single seam the shell has towards libbox. The default build has
// no linkable artifact, so it answers core_unavailable; a `libbox` build swaps in
// the adapter without touching the dispatcher.
type coreAPI interface {
	Configure(dataDir string)
	Capabilities() map[string]any
	CheckConfig(content string) (map[string]any, *bridgeError)
	FormatConfig(content string) (map[string]any, *bridgeError)
	Preview(content string) (map[string]any, *bridgeError)
	Refresh(tags []string, timeoutMillis int64) (map[string]any, *bridgeError)
	StartService(content string) *bridgeError
	StopService() *bridgeError
	Running() bool
}

type appliedProfile struct {
	id       string
	revision string
	content  string
}

type hostServer struct {
	sm      *stateMachine
	store   *profileStore
	core    coreAPI
	seq     int64
	eventMu sync.Mutex
	pending []map[string]any
	hooks   bool

	opMu   sync.Mutex
	active appliedProfile
	mode   string
	// proxyPort is the first positive listen_port in the applied document. Zero
	// means "not known"; the host never invents a port.
	proxyPort int
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
			"systemProxy": false,
			"perAppProxy": false,
			"autostart":   false,
			"tray":        false,
			"qrCamera":    false,
			// No QR image decoder ships with the Windows host yet; claiming it would
			// light up a dead UI entry (P4 QR strategy).
			"qrImageDecode":  false,
			"fileImport":     true,
			"clipboardWatch": true,
			"notifications":  false,
			"deepLink":       false,
			// Events are request/response only on this host today. The UI polls
			// service.status; claiming event delivery would be a lie until the
			// plugin's callback pump is implemented and tested.
			"events":         false,
			"memoryPressure": false,
			"serviceModes":   []string{"proxy"},
		})
	case "core.capabilities":
		return ok(req.ID, s.core.Capabilities())
	case "host.setup":
		return ok(req.ID, map[string]any{})
	case "host.shutdown":
		s.opMu.Lock()
		defer s.opMu.Unlock()
		if s.core.Running() {
			_ = s.core.StopService()
		}
		s.sm.close(s.sm.revision + 1)
		s.sm.runtimeReport(false, s.sm.revision)
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
		s.opMu.Lock()
		defer s.opMu.Unlock()
		revision := argInt(req.Args, "revision")
		mode := argString(req.Args, "mode")
		if mode == "" {
			mode = "proxy"
		}
		if revision <= s.sm.revision {
			return fail(req.ID, errStaleRevision)
		}
		if mode != "proxy" {
			return fail(req.ID, errUnsupportedPlatform("service mode "+mode))
		}
		profile, profileErr := s.resolveStartProfile(req.Args)
		if profileErr != nil {
			return fail(req.ID, profileErr)
		}
		if _, checkErr := s.core.CheckConfig(profile.content); checkErr != nil {
			return fail(req.ID, checkErr)
		}
		if !(s.core.Running() && s.active.id == profile.id &&
			s.active.revision == profile.revision) {
			if startErr := s.core.StartService(profile.content); startErr != nil {
				return fail(req.ID, startErr)
			}
		}
		outcome := s.sm.start(revision, false)
		if outcome == "rejected:closed" {
			_ = s.core.StopService()
			return fail(req.ID, &bridgeError{Code: "closed", Message: "host is shutting down", Retryable: false})
		}
		s.sm.runtimeReport(true, revision)
		s.active = profile
		s.mode = mode
		s.proxyPort = parseListenPort(profile.content)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{
			"accepted": true,
			"revision": revision,
		})
	case "service.stop":
		s.opMu.Lock()
		defer s.opMu.Unlock()
		revision := argInt(req.Args, "revision")
		if revision <= s.sm.revision {
			return fail(req.ID, errStaleRevision)
		}
		outcome := s.sm.stop(revision)
		if outcome == "rejected:closed" {
			return fail(req.ID, &bridgeError{Code: "closed", Message: "host is shutting down", Retryable: false})
		}
		if stopErr := s.core.StopService(); stopErr != nil {
			s.sm.failPending(stopErr.Message)
			return fail(req.ID, stopErr)
		}
		s.sm.runtimeReport(false, revision)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{
			"accepted": true,
			"revision": revision,
		})
	case "service.status":
		s.opMu.Lock()
		defer s.opMu.Unlock()
		s.syncRuntime()
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
		s.opMu.Lock()
		defer s.opMu.Unlock()
		if s.sm.closed {
			return fail(req.ID, &bridgeError{Code: "closed", Message: "host is shutting down", Retryable: false})
		}
		id := argString(req.Args, "id")
		expectedRevision := argString(req.Args, "revision")
		if mode := argString(req.Args, "mode"); mode == "vpn" {
			return fail(req.ID, errUnsupportedPlatform("service mode vpn"))
		}
		if id == "" {
			return fail(req.ID, errInvalidArgument("id is required"))
		}
		if expectedRevision == "" {
			return fail(req.ID, errInvalidArgument("revision is required"))
		}
		meta, body, readErr := s.store.Read(id)
		if readErr != nil {
			return fail(req.ID, errProfileNotFound(id))
		}
		if meta.Revision != expectedRevision {
			return fail(req.ID, errRevisionMismatch)
		}
		content := string(body)
		if _, checkErr := s.core.CheckConfig(content); checkErr != nil {
			return fail(req.ID, checkErr)
		}
		previous := s.active
		wasRunning := s.core.Running()
		if wasRunning {
			if startErr := s.core.StartService(content); startErr != nil {
				// The kernel keeps the old instance when a reload is rejected, but a
				// failed cold start leaves nothing running. Re-apply the last known
				// good document so the UI is never told "new config" while the old
				// proxy silently died.
				if previous.content != "" {
					if rollbackErr := s.core.StartService(previous.content); rollbackErr != nil {
						startErr.Details = map[string]any{
							"rollbackFailed": true,
							"rollbackError":  rollbackErr.Message,
						}
					} else {
						startErr.Details = map[string]any{"rolledBack": true}
					}
				}
				return fail(req.ID, startErr)
			}
		}
		nextRevision := s.sm.revision + 1
		if wasRunning {
			outcome := s.sm.start(nextRevision, false)
			if outcome == "rejected:closed" {
				_ = s.core.StopService()
				return fail(req.ID, &bridgeError{Code: "closed", Message: "host is shutting down", Retryable: false})
			}
			s.sm.runtimeReport(true, nextRevision)
		} else {
			s.sm.selectProfile(nextRevision)
		}
		s.active = appliedProfile{id: meta.ID, revision: meta.Revision, content: content}
		s.mode = "proxy"
		s.proxyPort = parseListenPort(content)
		s.emit("service.state", s.status())
		return ok(req.ID, map[string]any{
			"applied":          true,
			"requestId":        argString(req.Args, "requestId"),
			"switchedAtMillis": time.Now().UnixMilli(),
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
		// The host advertises these as false in host.capabilities; returning a
		// success-shaped object here was the reason a dead button looked alive.
		return fail(req.ID, errUnsupportedPlatform("Windows system integration"))
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

func (s *hostServer) resolveStartProfile(args map[string]any) (appliedProfile, *bridgeError) {
	id := argString(args, "profileId")
	if id == "" {
		if s.active.id == "" {
			return appliedProfile{}, errProfileNotFound("(none)")
		}
		return s.active, nil
	}
	meta, body, err := s.store.Read(id)
	if err != nil {
		return appliedProfile{}, errProfileNotFound(id)
	}
	expected := argString(args, "profileRevision")
	if expected != "" && meta.Revision != expected {
		return appliedProfile{}, errRevisionMismatch
	}
	return appliedProfile{id: meta.ID, revision: meta.Revision, content: string(body)}, nil
}

// syncRuntime makes status reflect the core, not the last intent. A core that
// died out-of-band must not keep reading as running.
func (s *hostServer) syncRuntime() {
	if s.sm.closed {
		return
	}
	running := s.core.Running()
	if running {
		s.sm.running = true
		if s.sm.pending == nil {
			s.sm.state = stateRunning
		}
		return
	}
	if s.sm.running {
		s.sm.running = false
		s.sm.fail("service.lost")
	}
}

func (s *hostServer) status() map[string]any {
	mode := s.mode
	if mode == "" {
		mode = "proxy"
	}
	status := map[string]any{
		"state":       s.sm.state,
		"revision":    s.sm.revision,
		"sinceMillis": 0,
		"mode":        mode,
		"tunActive":   false,
		"permission":  "granted",
		"profileId":   s.active.id,
		"profileRev":  s.active.revision,
	}
	if s.core.Running() && s.proxyPort > 0 {
		status["proxyPort"] = s.proxyPort
	}
	return status
}

func parseListenPort(content string) int {
	var document struct {
		Inbounds []struct {
			ListenPort int `json:"listen_port"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal([]byte(content), &document); err != nil {
		return 0
	}
	for _, inbound := range document.Inbounds {
		if inbound.ListenPort > 0 {
			return inbound.ListenPort
		}
	}
	return 0
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
