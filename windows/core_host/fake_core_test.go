package main

import (
	"strings"
	"sync"
)

// fakeCore is the service seam for dispatcher tests: it proves the host chooses
// the right document, reports errors instead of success, and re-applies the last
// good document when a reload fails. It never replaces the linked-core tests.
type fakeCore struct {
	mu       sync.Mutex
	dataDir  string
	running  bool
	started  []string
	checkErr *bridgeError
	// startErr decides per document whether StartService fails. It returns nil
	// for success.
	startErr func(content string) *bridgeError
	stopErr  *bridgeError
	stopCall int
}

func (f *fakeCore) Configure(dir string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.dataDir = dir
}

func (f *fakeCore) Capabilities() map[string]any {
	return map[string]any{"apiVersion": 4, "platform": "test"}
}

func (f *fakeCore) CheckConfig(content string) (map[string]any, *bridgeError) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.checkErr != nil {
		return nil, f.checkErr
	}
	if strings.Contains(content, "invalid") {
		return nil, &bridgeError{Code: "core_rejected_config", Message: "test config rejected", Retryable: false}
	}
	return map[string]any{"ok": true, "normalizedKind": "singbox-json"}, nil
}

func (f *fakeCore) FormatConfig(string) (map[string]any, *bridgeError) {
	return map[string]any{"content": ""}, nil
}

func (f *fakeCore) Preview(string) (map[string]any, *bridgeError) {
	return map[string]any{}, nil
}

func (f *fakeCore) Refresh([]string, int64) (map[string]any, *bridgeError) {
	return map[string]any{"supported": false}, nil
}

func (f *fakeCore) StartService(content string) *bridgeError {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.startErr != nil {
		if err := f.startErr(content); err != nil {
			return err
		}
	}
	f.started = append(f.started, content)
	f.running = true
	return nil
}

func (f *fakeCore) StopService() *bridgeError {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stopCall++
	if f.stopErr != nil {
		return f.stopErr
	}
	f.running = false
	return nil
}

func (f *fakeCore) Running() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.running
}
