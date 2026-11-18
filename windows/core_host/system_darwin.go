//go:build darwin

package main

// A user-level macOS helper is proxy-only. TUN needs root or a Network
// Extension, and changing the system proxy needs administrator rights; claiming
// either here would light a dead switch.
func sysCapabilities() map[string]any {
	return map[string]any{
		"systemProxy":   false,
		"autostart":     false,
		"tray":          false,
		"events":        false,
		"tun":           false,
		"serviceModes":  []string{"proxy"},
	}
}

func applySystemProxy(bool, int, []string) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("macOS system proxy needs administrator rights")
}

func systemProxyStatus(int) map[string]any {
	return map[string]any{
		"ourProxyActive":       false,
		"staleFromPreviousRun": false,
	}
}

func setAutoLaunch(bool, string) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("macOS autostart needs a LaunchAgent")
}

func autoLaunchStatus() bool { return false }
