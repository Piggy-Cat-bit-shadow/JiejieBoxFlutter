//go:build windows

package main

import (
	"net"

	"github.com/Microsoft/go-winio"
)

// listenJJBoxPipe serves the bridge on a Windows named pipe. The descriptor
// admits SYSTEM and the pipe owner (the interactive user that started the app);
// other local users cannot open it. Keeping the pipe as the default transport
// means the C++ plugin's `\\.\pipe\jjbox-host` has a real server and profile
// content does not travel over an unauthenticated loopback TCP socket.
func listenJJBoxPipe(name string) (net.Listener, error) {
	config := &winio.PipeConfig{
		SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;OW)",
	}
	return winio.ListenPipe(name, config)
}
