//go:build !windows

package main

import (
	"fmt"
	"net"
)

func listenJJBoxPipe(string) (net.Listener, error) {
	return nil, fmt.Errorf("named pipes are supported on Windows only")
}

func watchParent(int) {}
