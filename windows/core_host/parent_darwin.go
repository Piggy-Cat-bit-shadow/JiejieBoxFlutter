//go:build darwin

package main

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// watchParent polls the parent pid. A kqueue EVFILT_PROC would be lower latency,
// but polling is portable across the Go version pinned here and the failure mode
// (a short-lived orphan after a crash) is bounded to two seconds.
func watchParent(pid int) {
	if pid <= 0 {
		return
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		if err := unix.Kill(pid, 0); err != nil {
			os.Exit(0)
		}
	}
}
