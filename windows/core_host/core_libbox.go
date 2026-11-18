//go:build libbox

package main

import (
	"encoding/base64"
	stdjson "encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// This build links the pinned kernel module (experimental/libbox). It is produced by
// tools/build_core_host_libbox.ps1, which points a throwaway module at a read-only
// kernel checkout with the flutter-api patch applied; the committed go.mod stays
// dependency-free so the default host build keeps working without a kernel tree.
//
// TUN stays out on Windows: libbox's OpenInterface fails at dup/getTunnelName, so the
// host still advertises tun:false and only proxy mode is offered.

const coreLinked = true

type linkedCore struct {
	mu      sync.Mutex
	dataDir string
	server  *libbox.CommandServer
	client  *libbox.CommandClient
	handler *runtimeHandler
	sink    eventSink
	running bool
}

func defaultCore() coreAPI { return &linkedCore{} }

func (c *linkedCore) Configure(dataDir string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.dataDir = dataDir
}

func (linkedCore) Capabilities() map[string]any {
	return map[string]any{
		"apiVersion":   4,
		"buildId":      nil,
		"buildQuic":    true,
		"platform":     "windows",
		"version":      libbox.Version(),
		"goVersion":    runtime.Version(),
		"capabilities": []map[string]any{},
	}
}

// sanitizeCoreError keeps a core parse error useful without echoing document content.
// Credentials live in node documents, so the text is stripped of newlines, truncated and
// never includes the original config.
func sanitizeCoreError(err error) string {
	text := strings.Join(strings.Fields(err.Error()), " ")
	if len(text) > 300 {
		text = text[:300]
	}
	return text
}

func (linkedCore) CheckConfig(content string) (map[string]any, *bridgeError) {
	if err := libbox.CheckConfig(content); err != nil {
		return nil, &bridgeError{
			Code:      "core_rejected_config",
			Message:   sanitizeCoreError(err),
			Retryable: false,
			Details:   map[string]any{"coreText": sanitizeCoreError(err)},
		}
	}
	return map[string]any{"ok": true, "normalizedKind": "singbox-json"}, nil
}

func (linkedCore) FormatConfig(content string) (map[string]any, *bridgeError) {
	formatted, err := libbox.FormatConfig(content)
	if err != nil {
		return nil, &bridgeError{
			Code:      "core_rejected_config",
			Message:   sanitizeCoreError(err),
			Retryable: false,
			Details:   map[string]any{"coreText": sanitizeCoreError(err)},
		}
	}
	return map[string]any{"content": base64.StdEncoding.EncodeToString([]byte(formatted.Value))}, nil
}

func (linkedCore) Preview(content string) (map[string]any, *bridgeError) {
	preview, err := libbox.ParsePreview(content)
	if err != nil {
		return nil, &bridgeError{
			Code:      "invalid_argument",
			Message:   sanitizeCoreError(err),
			Retryable: false,
		}
	}
	var report map[string]any
	if err := stdjson.Unmarshal([]byte(preview.Value), &report); err != nil {
		return nil, &bridgeError{Code: "internal", Message: "preview decode failed", Retryable: false}
	}
	return report, nil
}

func (linkedCore) Refresh(tags []string, timeoutMillis int64) (map[string]any, *bridgeError) {
	// Refreshing needs a connected CommandClient and a running service; the host
	// does not expose that optional feature yet. Report it honestly.
	_ = tags
	_ = timeoutMillis
	return map[string]any{
		"supported":      false,
		"refreshed":      []string{},
		"failed":         map[string]string{},
		"durationMillis": 0,
	}, nil
}

// hostCommandHandler satisfies libbox.CommandServerHandler. The host owns the
// process lifecycle and does not register a system proxy, SSH agent or crash
// reporter, so these callbacks are deliberately inert. They must be non-nil for
// CommandServer to start.
type hostCommandHandler struct{}

func (hostCommandHandler) ServiceStop() error               { return nil }
func (hostCommandHandler) ServiceReload() error             { return nil }
func (hostCommandHandler) SetSystemProxyEnabled(bool) error { return nil }
func (hostCommandHandler) TriggerNativeCrash() error        { return nil }
func (hostCommandHandler) WriteDebugMessage(string)         {}
func (hostCommandHandler) ConnectSSHAgent() (int32, error) {
	return 0, errors.New("ssh agent is not available in the Windows host")
}

func (hostCommandHandler) GetSystemProxyStatus() (*libbox.SystemProxyStatus, error) {
	return &libbox.SystemProxyStatus{Available: false, Enabled: false}, nil
}

func (c *linkedCore) ensureLocked() *bridgeError {
	if c.server != nil {
		return nil
	}
	if c.dataDir == "" {
		return &bridgeError{Code: "core_unavailable", Message: "host data directory is not configured", Retryable: false}
	}
	workPath := filepath.Join(c.dataDir, "core")
	tempPath := filepath.Join(c.dataDir, "temp")
	if err := os.MkdirAll(workPath, 0o755); err != nil {
		return &bridgeError{Code: "storage_write_failed", Message: "create core working directory", Retryable: true}
	}
	if err := os.MkdirAll(tempPath, 0o755); err != nil {
		return &bridgeError{Code: "storage_write_failed", Message: "create core temp directory", Retryable: true}
	}
	if err := libbox.Setup(&libbox.SetupOptions{
		BasePath:          c.dataDir,
		WorkingPath:       workPath,
		TempPath:          tempPath,
		LogMaxLines:       1000,
		CrashReportSource: "windows-host",
	}); err != nil {
		return &bridgeError{Code: "core_unavailable", Message: sanitizeCoreError(err), Retryable: true}
	}
	server, err := libbox.NewCommandServer(hostCommandHandler{}, &hostPlatform{})
	if err != nil {
		return &bridgeError{Code: "core_unavailable", Message: sanitizeCoreError(err), Retryable: true}
	}
	// Start binds the command channel the runtime client dials. It is loopback-only
	// (unix socket first, then 127.0.0.1) and authenticated by the per-process secret
	// libbox keeps in its package globals; nothing is exposed off-host.
	if err := server.Start(); err != nil {
		server.Close()
		return &bridgeError{Code: "core_unavailable", Message: sanitizeCoreError(err), Retryable: true}
	}
	c.server = server
	return nil
}

func (c *linkedCore) StartService(content string) *bridgeError {
	if strings.TrimSpace(content) == "" {
		return &bridgeError{Code: "invalid_argument", Message: "config content is empty", Retryable: false}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureLocked(); err != nil {
		return err
	}
	if err := c.server.StartOrReloadService(content, &libbox.OverrideOptions{}); err != nil {
		return &bridgeError{
			Code:      "core_start_failed",
			Message:   sanitizeCoreError(err),
			Retryable: true,
			Details:   map[string]any{"coreText": sanitizeCoreError(err)},
		}
	}
	c.running = true
	// Attach the runtime client only after the Box runs: the client subscribes to a
	// service, and a subscription against a stopped core would report an empty state
	// that looks like a real one.
	if runtimeErr := c.startRuntimeLocked(); runtimeErr != nil {
		return runtimeErr
	}
	return nil
}

func (c *linkedCore) StopService() *bridgeError {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.server == nil || !c.running {
		return nil
	}
	c.stopRuntimeLocked()
	if err := c.server.CloseService(); err != nil {
		return &bridgeError{Code: "core_stop_failed", Message: sanitizeCoreError(err), Retryable: true}
	}
	c.running = false
	return nil
}

func (c *linkedCore) Running() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running
}

// hostPlatform is the minimal PlatformInterface for a proxy-only Windows host.
// It intentionally exposes no TUN, no VPN service and no platform dialer: the
// host owns a loopback proxy, and the OS routes traffic to it through the app's
// WinINet integration (which this host currently reports as unsupported).
type hostPlatform struct{}

func (hostPlatform) LocalDNSTransport() libbox.LocalDNSTransport { return nil }
func (hostPlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }
func (hostPlatform) AutoDetectInterfaceControl(int32) error      { return nil }
func (hostPlatform) OpenTun(libbox.TunOptions) (int32, error) {
	return 0, errors.New("TUN is not available in the Windows host")
}
func (hostPlatform) FindConnectionOwner(int32, string, int32, string, int32) (*libbox.ConnectionOwner, error) {
	return nil, errors.New("connection owner lookup is not available in the Windows host")
}
func (hostPlatform) StartDefaultInterfaceMonitor(listener libbox.InterfaceUpdateListener) error {
	if listener != nil {
		listener.UpdateDefaultInterface("", -1, false, false)
		listener.UpdateNetworkPath("")
	}
	return nil
}
func (hostPlatform) CloseDefaultInterfaceMonitor(libbox.InterfaceUpdateListener) error { return nil }
func (hostPlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error)           { return nil, nil }
func (hostPlatform) UnderNetworkExtension() bool                                       { return false }
func (hostPlatform) IncludeAllNetworks() bool                                          { return false }
func (hostPlatform) ReadWIFIState() *libbox.WIFIState                                  { return nil }
func (hostPlatform) ClearDNSCache()                                                    {}
func (hostPlatform) SendNotification(*libbox.Notification) error                       { return nil }
func (hostPlatform) CancelNotification(string, int32) error                            { return nil }
func (hostPlatform) StartNeighborMonitor(libbox.NeighborUpdateListener) error          { return nil }
func (hostPlatform) CloseNeighborMonitor(libbox.NeighborUpdateListener) error          { return nil }
func (hostPlatform) RegisterMyInterface(string)                                        {}
func (hostPlatform) UsePlatformShell() bool                                            { return false }
func (hostPlatform) CheckPlatformShell() error                                         { return nil }
func (hostPlatform) OpenShellSession(*libbox.PlatformUser, string, libbox.StringIterator, string, int32, int32) (libbox.ShellSession, error) {
	return nil, errors.New("shell is not available in the Windows host")
}
func (hostPlatform) LookupUser(string) (*libbox.PlatformUser, error) {
	return nil, errors.New("user lookup is not available in the Windows host")
}
func (hostPlatform) LookupSFTPServer() (string, error) {
	return "", errors.New("SFTP is not available in the Windows host")
}
func (hostPlatform) ReadSystemSSHHostKey() (string, error) {
	return "", errors.New("SSH host key is not available in the Windows host")
}
func (hostPlatform) TailscaleHostname() string { return "" }
func (hostPlatform) UsePlatformBridge() bool   { return false }
func (hostPlatform) CreateBridge(*libbox.BridgeOptions) (libbox.BridgeSession, error) {
	return nil, errors.New("platform bridge is not available in the Windows host")
}
func (hostPlatform) UsePlatformAutoRedirect() bool { return false }
func (hostPlatform) CreateAutoRedirect([]byte, libbox.AutoRedirectHandler) (libbox.AutoRedirectSession, error) {
	return nil, errors.New("auto redirect is not available in the Windows host")
}
