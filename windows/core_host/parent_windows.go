//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

const (
	parentSynchronize = 0x00100000
	parentInfinite    = 0xFFFFFFFF
)

// watchParent exits the host when the process that started it disappears, so a
// crashed or force-killed Flutter app cannot leave an orphaned core running.
func watchParent(pid int) {
	handle, err := windows.OpenProcess(parentSynchronize, false, uint32(pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(handle)
	_, _ = windows.WaitForSingleObject(handle, parentInfinite)
	os.Exit(0)
}
