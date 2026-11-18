//go:build windows

package main

import (
	"fmt"
	"net"
)

// Unix sockets are not part of the Windows product transport; the named pipe is.
// Defining the symbol keeps the shared main.go buildable and turns an accidental
// --socket flag into a clear error instead of a silent no-op.
func listenJJBoxSocket(string) (net.Listener, error) {
	return nil, fmt.Errorf("Unix sockets are not supported on Windows")
}
