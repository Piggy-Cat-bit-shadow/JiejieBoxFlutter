//go:build !windows

package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// listenJJBoxSocket is the macOS/Linux transport. The macOS plugin spawns this
// helper with a short path it owns (Darwin sun_path is 103 bytes), so the helper
// never guesses an Application Support path that an App Sandbox container would
// make too long.
func listenJJBoxSocket(path string) (net.Listener, error) {
	if path == "" {
		return nil, fmt.Errorf("empty unix socket path")
	}
	if len(path) > 100 {
		return nil, fmt.Errorf("unix socket path is %d bytes; Darwin allows at most 103", len(path))
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, err
	}
	return listener, nil
}
