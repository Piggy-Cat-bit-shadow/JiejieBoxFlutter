package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
)

// Windows named pipes carry the same frame the C++ plugin writes: an 8-byte
// little-endian header (payload length, reserved) followed by one JSON envelope.
// The TCP transport keeps the newline-delimited form the Dart SocketHostTransport
// and the Go E2E tests use, so both sides stay compatible without a second codec.
const maxFramedPayload = 8 * 1024 * 1024

func (s *hostServer) serveFramed(listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go s.handleFramedConn(conn)
	}
}

func (s *hostServer) handleFramedConn(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	for {
		var header [8]byte
		if _, err := io.ReadFull(reader, header[:]); err != nil {
			return
		}
		length := binary.LittleEndian.Uint32(header[:4])
		if length > maxFramedPayload {
			return
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return
		}
		var req request
		if err := json.Unmarshal(payload, &req); err != nil {
			if !s.writeFrame(conn, fail("", errInvalidArgument("malformed frame"))) {
				return
			}
			continue
		}
		if !s.writeFrame(conn, s.Handle(req)) {
			return
		}
	}
}

func (s *hostServer) writeFrame(conn net.Conn, response response) bool {
	encoded, err := json.Marshal(response)
	if err != nil {
		return false
	}
	var header [8]byte
	binary.LittleEndian.PutUint32(header[:4], uint32(len(encoded)))
	if _, err := conn.Write(header[:]); err != nil {
		return false
	}
	_, err = conn.Write(encoded)
	return err == nil
}
