//go:build !libbox

package main

// The default build has no kernel module. That is an honest, permanent answer for
// this binary: config checks need a linked libbox, and Windows TUN is not available
// in libbox anyway (C-GAP-WIN-LIBBOX-TUN). The shell therefore advertises core:false
// and answers config.* with unsupported_platform instead of pretending the core is
// merely stopped.

const coreLinked = false

type unlinkedCore struct{}

func defaultCore() coreAPI { return unlinkedCore{} }

func (unlinkedCore) Capabilities() map[string]any {
	return map[string]any{
		"apiVersion":   0,
		"buildId":      nil,
		"buildQuic":    false,
		"platform":     "windows",
		"version":      "0.1.0-shell",
		"goVersion":    nil,
		"capabilities": []map[string]any{},
	}
}

func (unlinkedCore) CheckConfig(string) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("config.check needs a libbox-linked host build")
}

func (unlinkedCore) FormatConfig(string) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("config.format needs a libbox-linked host build")
}

func (unlinkedCore) Preview(string) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("config.preview needs a libbox-linked host build")
}

func (unlinkedCore) Refresh([]string, int64) (map[string]any, *bridgeError) {
	return nil, errUnsupportedPlatform("provider.refresh needs a running core service")
}
