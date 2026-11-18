//go:build libbox

package main

// The linked implementation of the runtime bridge: one CommandClient that follows the
// running Box and turns its callback streams into contract events.
//
// The client is created when a service starts and disconnected when it stops. It is NOT
// recreated per UI call: one connection carries status/groups/logs/connections for the
// lifetime of the service, which is what keeps an UI rebuild from becoming a reconnect.

import (
	stdjson "encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// runtimeHandler implements libbox.CommandClientHandler. Every method runs on a gRPC
// callback goroutine, so it must not block and must not touch host state without a lock.
type runtimeHandler struct {
	sink eventSink

	mu       sync.Mutex
	modes    []string
	current  string
	instance string
	// stopping marks an intentional detach (service stop / host shutdown). The client
	// reports Disconnected for both a stop and a lost core, and only the latter is a
	// failure: emitting "failed" after a user-initiated stop would make the UI flash an
	// error on every normal stop.
	stopping bool

	statusInterval time.Duration
}

func (h *runtimeHandler) markStopping() {
	h.mu.Lock()
	h.stopping = true
	h.mu.Unlock()
}

func newRuntimeHandler(sink eventSink) *runtimeHandler {
	return &runtimeHandler{sink: sink, statusInterval: time.Second}
}

func (h *runtimeHandler) emit(kind string, data map[string]any) {
	if h.sink != nil {
		h.sink(kind, data)
	}
}

func (h *runtimeHandler) Connected() {}

func (h *runtimeHandler) Disconnected(message string) {
	h.mu.Lock()
	stopping := h.stopping
	h.mu.Unlock()
	if stopping {
		// Intentional detach: service.state already carries the authoritative lifecycle.
		return
	}
	h.emit(eventRuntimeStatus, map[string]any{
		"serviceState":     stateFailed,
		"reason":           trimForEvent(message, 300),
		"trafficAvailable": false,
	})
}

func (h *runtimeHandler) SetDefaultLogLevel(int32) {}

func (h *runtimeHandler) ClearLogs() {
	h.emit(eventLogsCleared, map[string]any{})
}

func (h *runtimeHandler) WriteLogs(messages libbox.LogIterator) {
	entries := make([]map[string]any, 0, 16)
	for messages != nil && messages.HasNext() {
		entry := messages.Next()
		if entry == nil {
			continue
		}
		entries = append(entries, map[string]any{
			"level":   entry.Level,
			"name":    logLevelName(entry.Level),
			"message": redactLog(entry.Message),
			"at":      time.Now().UnixMilli(),
		})
	}
	if len(entries) > 0 {
		h.emit(eventRuntimeLog, map[string]any{"entries": entries})
	}
}

func (h *runtimeHandler) WriteStatus(message *libbox.StatusMessage) {
	if message == nil {
		return
	}
	h.emit(eventRuntimeStatus, map[string]any{
		"serviceState":       stateRunning,
		"memoryBytes":        message.Memory,
		"goroutines":         message.Goroutines,
		"connectionsIn":      message.ConnectionsIn,
		"connectionsOut":     message.ConnectionsOut,
		"trafficAvailable":   message.TrafficAvailable,
		"uplinkBytes":        message.Uplink,
		"downlinkBytes":      message.Downlink,
		"uplinkTotalBytes":   message.UplinkTotal,
		"downlinkTotalBytes": message.DownlinkTotal,
		"sampledAt":          time.Now().UnixMilli(),
	})
}

func (h *runtimeHandler) WriteGroups(message libbox.OutboundGroupIterator) {
	groups := make([]map[string]any, 0, 8)
	for message != nil && message.HasNext() {
		group := message.Next()
		if group == nil {
			continue
		}
		items := make([]map[string]any, 0, 8)
		itemIterator := group.GetItems()
		for itemIterator != nil && itemIterator.HasNext() {
			item := itemIterator.Next()
			if item == nil {
				continue
			}
			items = append(items, map[string]any{
				"tag":          item.Tag,
				"type":         item.Type,
				"urlTestTime":  item.URLTestTime,
				"urlTestDelay": item.URLTestDelay,
			})
		}
		groups = append(groups, map[string]any{
			"tag":        group.Tag,
			"type":       group.Type,
			"selectable": group.Selectable,
			"selected":   group.Selected,
			"expanded":   group.IsExpand,
			"items":      items,
		})
	}
	if os.Getenv("JJ_RT_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "[rt] WriteGroups count=%d\n", len(groups))
	}
	h.emit(eventRuntimeGroups, map[string]any{"groups": groups})
}

// WriteOutbounds carries per-outbound details; the group payload already includes the
// members, so this stream is acknowledged rather than duplicated into a second shape.
func (h *runtimeHandler) WriteOutbounds(libbox.OutboundGroupItemIterator) {}

func (h *runtimeHandler) InitializeClashMode(modeList libbox.StringIterator, currentMode string) {
	modes := make([]string, 0, 4)
	for modeList != nil && modeList.HasNext() {
		modes = append(modes, modeList.Next())
	}
	h.mu.Lock()
	h.modes = modes
	h.current = currentMode
	h.mu.Unlock()
	h.emit(eventRuntimeModes, map[string]any{
		"modes":     modes,
		"current":   currentMode,
		"available": len(modes) > 0,
	})
}

func (h *runtimeHandler) UpdateClashMode(newMode string) {
	h.mu.Lock()
	h.current = newMode
	modes := append([]string(nil), h.modes...)
	h.mu.Unlock()
	h.emit(eventRuntimeModes, map[string]any{
		"modes":     modes,
		"current":   newMode,
		"available": len(modes) > 0,
	})
}

func (h *runtimeHandler) WriteConnectionEvents(events *libbox.ConnectionEvents) {
	if events == nil {
		return
	}
	h.mu.Lock()
	if events.InstanceId != "" {
		h.instance = events.InstanceId
	}
	instance := h.instance
	h.mu.Unlock()

	encoded := make([]map[string]any, 0, 16)
	iterator := events.Iterator()
	for iterator != nil && iterator.HasNext() {
		event := iterator.Next()
		if event == nil {
			continue
		}
		entry := map[string]any{"type": connectionEventType(event.Type)}
		if event.ID != "" {
			entry["id"] = event.ID
		}
		if connection := event.Connection; connection != nil {
			entry["network"] = connection.Network
			entry["source"] = connection.Source
			entry["destination"] = connection.Destination
			entry["domain"] = connection.Domain
			entry["outbound"] = connection.Outbound
			entry["outboundType"] = connection.OutboundType
			entry["rule"] = connection.Rule
			entry["protocol"] = connection.Protocol
			entry["createdAt"] = connection.CreatedAt
			entry["uplinkTotalBytes"] = connection.UplinkTotal
			entry["downlinkTotalBytes"] = connection.DownlinkTotal
			chain := make([]string, 0, 2)
			chainIterator := connection.Chain()
			for chainIterator != nil && chainIterator.HasNext() {
				chain = append(chain, chainIterator.Next())
			}
			entry["chain"] = chain
		}
		if event.UplinkDelta != 0 {
			entry["uplinkDelta"] = event.UplinkDelta
		}
		if event.DownlinkDelta != 0 {
			entry["downlinkDelta"] = event.DownlinkDelta
		}
		if event.ClosedAt != 0 {
			entry["closedAt"] = event.ClosedAt
		}
		encoded = append(encoded, entry)
	}
	h.emit(eventRuntimeConnections, map[string]any{
		"reset":      events.Reset,
		"instanceId": instance,
		"resynced":   events.Resynced,
		"sequence":   events.Sequence(),
		"dropped":    events.Dropped(),
		"events":     encoded,
	})
}

func connectionEventType(value int32) string {
	switch value {
	case libbox.ConnectionEventNew:
		return "new"
	case libbox.ConnectionEventUpdate:
		return "update"
	case libbox.ConnectionEventClosed:
		return "closed"
	default:
		return "unknown"
	}
}

// --- linkedCore runtime surface -------------------------------------------------

// runtimeUnavailable is the honest answer when no service is running: runtime commands
// need a live Box, and saying "not running" beats a fabricated empty payload.
func runtimeUnavailable() *bridgeError {
	return &bridgeError{
		Code:      "unsupported_platform",
		Message:   "the core service is not running",
		Retryable: true,
	}
}

// startRuntimeLocked attaches a CommandClient to the running command server. Called with
// c.mu held.
func (c *linkedCore) startRuntimeLocked() *bridgeError {
	if c.sink == nil {
		return nil // runtime events are not requested yet; the service still runs
	}
	if c.client != nil {
		return nil
	}
	handler := newRuntimeHandler(c.sink)
	options := &libbox.CommandClientOptions{StatusInterval: int64(time.Second)}
	// A client with no commands subscribes to nothing: the control plane answers calls but
	// no stream is opened, which is why the first runtime selftest saw no groups. Subscribe
	// to every stream the contract covers.
	options.AddCommand(libbox.CommandStatus)
	options.AddCommand(libbox.CommandGroup)
	options.AddCommand(libbox.CommandLog)
	options.AddCommand(libbox.CommandClashMode)
	options.AddCommand(libbox.CommandConnections)
	client := libbox.NewCommandClient(handler, options)
	if err := client.Connect(); err != nil {
		client.Disconnect()
		return &bridgeError{Code: "core_unavailable", Message: sanitizeCoreError(err), Retryable: true}
	}
	c.client = client
	c.handler = handler
	return nil
}

// stopRuntimeLocked detaches the client before the service goes away. Called with c.mu
// held.
func (c *linkedCore) stopRuntimeLocked() {
	if c.client != nil {
		if c.handler != nil {
			// Mark before Disconnect: the callback runs on the client's goroutine and a
			// stop must not be reported as a lost core.
			c.handler.markStopping()
		}
		_ = c.client.Disconnect()
		c.client = nil
		c.handler = nil
	}
}

func (c *linkedCore) SubscribeRuntime(sink eventSink) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sink = sink
	if c.running && c.client == nil {
		if err := c.startRuntimeLocked(); err != nil {
			return err
		}
	}
	return nil
}

func (c *linkedCore) UnsubscribeRuntime() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sink = nil
	c.stopRuntimeLocked()
}

func (c *linkedCore) SelectOutbound(groupTag, outboundTag, requestID string, expectedRevision int64) (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	if strings.TrimSpace(groupTag) == "" || strings.TrimSpace(outboundTag) == "" {
		return nil, &bridgeError{Code: "invalid_argument", Message: "group and outbound are required", Retryable: false}
	}
	// The kernel's typed variant carries the caller's identity plus the revision the
	// caller read; a stale revision is refused there, not silently applied here.
	// The binding takes int64 (gomobile cannot bind uint64), so a string request id is
	// parsed and a non-numeric one is refused rather than silently dropped.
	if requestID == "" {
		if err := client.SelectOutbound(groupTag, outboundTag); err != nil {
			return nil, &bridgeError{Code: "core_select_failed", Message: sanitizeCoreError(err), Retryable: true}
		}
		return map[string]any{"accepted": true, "group": groupTag, "outbound": outboundTag, "confirmed": false}, nil
	}
	requestNumber, parseErr := strconv.ParseInt(requestID, 10, 64)
	if parseErr != nil {
		return nil, &bridgeError{Code: "invalid_argument", Message: "requestId must be numeric", Retryable: false}
	}
	boxed, err := client.SelectOutboundWithRequest(groupTag, outboundTag, requestNumber, expectedRevision)
	if err != nil {
		code := "core_select_failed"
		if strings.Contains(strings.ToLower(err.Error()), "revision") {
			code = "revision_mismatch"
		}
		return nil, &bridgeError{Code: code, Message: sanitizeCoreError(err), Retryable: code == "revision_mismatch"}
	}
	payload := map[string]any{"accepted": true, "group": groupTag, "outbound": outboundTag}
	if boxed != nil && boxed.Value != "" {
		var decoded map[string]any
		if decodeErr := stdjson.Unmarshal([]byte(boxed.Value), &decoded); decodeErr == nil {
			for key, value := range decoded {
				payload[key] = value
			}
		}
	}
	// The kernel's document names the read-back field appliedOutboundTag; the contract
	// calls it appliedOutbound. Publish both so a consumer can use the contract name
	// without a second mapping table.
	if applied, ok := payload["appliedOutboundTag"]; ok {
		if _, present := payload["appliedOutbound"]; !present {
			payload["appliedOutbound"] = applied
		}
	}
	return payload, nil
}

func (c *linkedCore) URLTest(groupTag, outboundTag string) (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	target := outboundTag
	if target == "" {
		target = groupTag
	}
	if target == "" {
		return nil, &bridgeError{Code: "invalid_argument", Message: "a group or outbound is required", Retryable: false}
	}
	if err := client.URLTest(target); err != nil {
		return nil, &bridgeError{Code: "core_urltest_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	// URLTest has no synchronous result; the delay arrives in the next groups frame.
	return map[string]any{"accepted": true, "target": target}, nil
}

func (c *linkedCore) URLTestCancel(groupTag string) (map[string]any, *bridgeError) {
	// The kernel exposes no cancellation for URLTest. Reporting "accepted" would be a
	// lie, so the honest answer is that this build cannot cancel it.
	return nil, &bridgeError{
		Code:      "unsupported_platform",
		Message:   "the kernel does not expose URLTest cancellation",
		Retryable: false,
	}
}

func (c *linkedCore) SetMode(mode string) (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	handler := c.handler
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	if handler != nil {
		handler.mu.Lock()
		modes := append([]string(nil), handler.modes...)
		handler.mu.Unlock()
		if len(modes) > 0 {
			found := false
			for _, candidate := range modes {
				if candidate == mode {
					found = true
					break
				}
			}
			if !found {
				return nil, &bridgeError{Code: "mode_not_available", Message: "mode " + mode + " is not offered by this profile", Retryable: false}
			}
		}
	}
	if err := client.SetClashMode(mode); err != nil {
		return nil, &bridgeError{Code: "core_mode_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	return map[string]any{"accepted": true, "mode": mode}, nil
}

func (c *linkedCore) Modes() (map[string]any, *bridgeError) {
	c.mu.Lock()
	handler := c.handler
	running := c.running
	c.mu.Unlock()
	if !running || handler == nil {
		return map[string]any{"modes": []string{}, "current": "", "available": false}, nil
	}
	handler.mu.Lock()
	defer handler.mu.Unlock()
	modes := append([]string(nil), handler.modes...)
	return map[string]any{"modes": modes, "current": handler.current, "available": len(modes) > 0}, nil
}

func (c *linkedCore) RefreshProviders(tags []string, timeoutMillis int64) (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	started := time.Now()
	box, err := client.RefreshRemoteProviders(strings.Join(tags, ","), timeoutMillis)
	if err != nil {
		return nil, &bridgeError{Code: "provider_refresh_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	result := map[string]any{}
	if box != nil && box.Value != "" {
		if decodeErr := stdjson.Unmarshal([]byte(box.Value), &result); decodeErr != nil {
			return nil, &bridgeError{Code: "internal", Message: "provider refresh response is not JSON", Retryable: false}
		}
	}
	if _, present := result["supported"]; !present {
		result["supported"] = true
	}
	result["durationMillis"] = time.Since(started).Milliseconds()
	return result, nil
}

func (c *linkedCore) CloseConnection(id string) (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	if strings.TrimSpace(id) == "" {
		return nil, &bridgeError{Code: "invalid_argument", Message: "connection id is required", Retryable: false}
	}
	if err := client.CloseConnection(id); err != nil {
		return nil, &bridgeError{Code: "core_close_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	return map[string]any{"accepted": true, "id": id}, nil
}

func (c *linkedCore) CloseConnections() (map[string]any, *bridgeError) {
	c.mu.Lock()
	client := c.client
	c.mu.Unlock()
	if client == nil {
		return nil, runtimeUnavailable()
	}
	if err := client.CloseConnections(); err != nil {
		return nil, &bridgeError{Code: "core_close_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	return map[string]any{"accepted": true}, nil
}
