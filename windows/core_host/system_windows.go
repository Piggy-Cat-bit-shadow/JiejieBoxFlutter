//go:build windows

package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"

	"golang.org/x/sys/windows/registry"
)

const (
	internetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	proxyBackupKey      = `Software\JiejieBox\SystemProxyBackup`
	runKey              = `Software\Microsoft\Windows\CurrentVersion\Run`
)

var systemMu sync.Mutex

// proxyBackup is written before the first change we make. It is deliberately in
// the registry rather than a temp file so a crash still leaves enough state to
// restore the user's previous WinINet setting.
type proxyBackup struct {
	applied  bool
	enabled  uint32
	server   string
	override string
}

func readProxyBackup() proxyBackup {
	key, err := registry.OpenKey(registry.CURRENT_USER, proxyBackupKey, registry.QUERY_VALUE)
	if err != nil {
		return proxyBackup{}
	}
	defer key.Close()
	applied, _, _ := key.GetIntegerValue("applied")
	enabled, _, _ := key.GetIntegerValue("enabled")
	server, _, _ := key.GetStringValue("server")
	override, _, _ := key.GetStringValue("override")
	return proxyBackup{
		applied:  applied == 1,
		enabled:  uint32(enabled),
		server:   server,
		override: override,
	}
}

func writeProxyBackup(backup proxyBackup) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, proxyBackupKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	applied := uint32(0)
	if backup.applied {
		applied = 1
	}
	if err := key.SetDWordValue("applied", applied); err != nil {
		return err
	}
	if err := key.SetDWordValue("enabled", backup.enabled); err != nil {
		return err
	}
	if err := key.SetStringValue("server", backup.server); err != nil {
		return err
	}
	return key.SetStringValue("override", backup.override)
}

func clearProxyBackup() {
	_ = registry.DeleteKey(registry.CURRENT_USER, proxyBackupKey)
}

func currentProxy() (enabled uint32, server, override string) {
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsKey, registry.QUERY_VALUE)
	if err != nil {
		return 0, "", ""
	}
	defer key.Close()
	value, _, _ := key.GetIntegerValue("ProxyEnable")
	server, _, _ = key.GetStringValue("ProxyServer")
	override, _, _ = key.GetStringValue("ProxyOverride")
	return uint32(value), server, override
}

func setCurrentProxy(enabled uint32, server, override string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, internetSettingsKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if err := key.SetDWordValue("ProxyEnable", enabled); err != nil {
		return err
	}
	if server == "" {
		_ = key.DeleteValue("ProxyServer")
	} else if err := key.SetStringValue("ProxyServer", server); err != nil {
		return err
	}
	if override == "" {
		_ = key.DeleteValue("ProxyOverride")
	} else if err := key.SetStringValue("ProxyOverride", override); err != nil {
		return err
	}
	notifyProxyChanged()
	return nil
}

func notifyProxyChanged() {
	wininet := syscall.NewLazyDLL("wininet.dll")
	proc := wininet.NewProc("InternetSetOptionW")
	// INTERNET_OPTION_SETTINGS_CHANGED (39) and REFRESH (37).
	_, _, _ = proc.Call(0, 39, 0, 0)
	_, _, _ = proc.Call(0, 37, 0, 0)
}

func isOurProxy(server string, port int) bool {
	if port <= 0 {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(server), fmt.Sprintf("127.0.0.1:%d", port))
}

func applySystemProxy(enabled bool, port int, bypass []string) (map[string]any, *bridgeError) {
	systemMu.Lock()
	defer systemMu.Unlock()

	if enabled {
		if port <= 0 {
			return nil, errInvalidArgument("proxy port is not known yet")
		}
		backup := readProxyBackup()
		if !backup.applied {
			previousEnabled, previousServer, previousOverride := currentProxy()
			backup = proxyBackup{
				applied:  true,
				enabled:  previousEnabled,
				server:   previousServer,
				override: previousOverride,
			}
			if err := writeProxyBackup(backup); err != nil {
				return nil, &bridgeError{Code: "system_proxy_failed", Message: "save previous proxy setting", Retryable: true}
			}
		}
		override := strings.Join(bypass, ";")
		if err := setCurrentProxy(1, fmt.Sprintf("127.0.0.1:%d", port), override); err != nil {
			return nil, &bridgeError{Code: "system_proxy_failed", Message: "write WinINet proxy setting", Retryable: true}
		}
		return map[string]any{"applied": true, "port": port}, nil
	}

	backup := readProxyBackup()
	currentEnabled, currentServer, _ := currentProxy()
	if !backup.applied {
		// Never disable a proxy we do not own.
		return map[string]any{"applied": false, "restored": false}, nil
	}
	// If the user changed the proxy after us, do not overwrite that change. A
	// zero port means "restore the saved setting", used during stale cleanup.
	if port > 0 && currentEnabled != 0 && !isOurProxy(currentServer, port) && currentServer != "" {
		clearProxyBackup()
		return map[string]any{"applied": false, "restored": false}, nil
	}
	if err := setCurrentProxy(backup.enabled, backup.server, backup.override); err != nil {
		return nil, &bridgeError{Code: "system_proxy_failed", Message: "restore WinINet proxy setting", Retryable: true}
	}
	clearProxyBackup()
	return map[string]any{"applied": false, "restored": true}, nil
}

func systemProxyStatus(port int) map[string]any {
	systemMu.Lock()
	defer systemMu.Unlock()
	enabled, server, _ := currentProxy()
	backup := readProxyBackup()
	ours := enabled != 0 && isOurProxy(server, port)
	return map[string]any{
		"ourProxyActive":       ours,
		"port":                 port,
		"staleFromPreviousRun": backup.applied && !ours,
	}
}

func setAutoLaunch(enabled bool, appExe string) (map[string]any, *bridgeError) {
	systemMu.Lock()
	defer systemMu.Unlock()
	key, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE|registry.QUERY_VALUE)
	if err != nil {
		return nil, &bridgeError{Code: "autostart_failed", Message: "open Run key", Retryable: true}
	}
	defer key.Close()
	const valueName = "JiejieBox"
	if !enabled {
		_ = key.DeleteValue(valueName)
		return map[string]any{"enabled": false}, nil
	}
	if appExe == "" {
		return nil, errInvalidArgument("app executable path is not known")
	}
	if _, err := os.Stat(appExe); err != nil {
		return nil, errInvalidArgument("app executable does not exist")
	}
	if err := key.SetStringValue(valueName, `"`+appExe+`"`); err != nil {
		return nil, &bridgeError{Code: "autostart_failed", Message: "write Run key", Retryable: true}
	}
	return map[string]any{"enabled": true}, nil
}

func autoLaunchStatus() bool {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer key.Close()
	_, _, err = key.GetStringValue("JiejieBox")
	return err == nil
}

func sysCapabilities() map[string]any {
	return map[string]any{
		"systemProxy":  true,
		"autostart":    true,
		"tray":         true,
		"events":       true,
		"tun":          false,
		"serviceModes": []string{"proxy"},
	}
}
