//go:build windows

package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
)

// TestPipeFramedCapabilities proves the C++ plugin's frame shape reaches the
// host over the default named pipe: 8-byte little-endian header + JSON envelope.
func TestPipeFramedCapabilities(t *testing.T) {
	store, err := newProfileStore(t.TempDir())
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	server := newHostServer(store, defaultCore())
	name := fmt.Sprintf(`\\.\pipe\jjbox-test-%d`, os.Getpid())
	listener, err := listenJJBoxPipe(name)
	if err != nil {
		t.Fatalf("listen pipe: %v", err)
	}
	defer listener.Close()
	go server.serveFramed(listener)

	conn, err := winio.DialPipe(name, nil)
	if err != nil {
		t.Fatalf("dial pipe: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	payload := []byte(`{"id":"1","method":"host.capabilities"}`)
	var header [8]byte
	binary.LittleEndian.PutUint32(header[:4], uint32(len(payload)))
	if _, err := conn.Write(header[:]); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write payload: %v", err)
	}

	if _, err := io.ReadFull(conn, header[:]); err != nil {
		t.Fatalf("read header: %v", err)
	}
	length := binary.LittleEndian.Uint32(header[:4])
	reply := make([]byte, length)
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatalf("read payload: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(reply, &decoded); err != nil {
		t.Fatalf("decode: %v (%s)", err, reply)
	}
	if decoded["ok"] != true {
		t.Fatalf("capabilities failed: %s", reply)
	}
}
