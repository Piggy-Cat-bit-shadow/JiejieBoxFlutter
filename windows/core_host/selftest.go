package main

import (
	"errors"
	"fmt"
)

// runSelfTest drives the shell the way the Dart bridge does: an ack that must not
// read as running, runtime evidence that does, a stop, the unlinked-core answer,
// profile storage and an unknown method. It is the check `core_host --selftest`
// runs on the Windows host.
func runSelfTest(server *hostServer) error {
	checks := 0
	expect := func(condition bool, message string) error {
		if !condition {
			return errors.New(message)
		}
		checks++
		return nil
	}
	resultOf := func(response response) map[string]any {
		value, _ := response.Result.(map[string]any)
		return value
	}

	caps := server.Handle(request{ID: "1", Method: "host.capabilities"})
	if err := expect(resultOf(caps)["qrImageDecode"] == false,
		"Windows must not claim QR image decoding without a decoder"); err != nil {
		return err
	}
	if err := expect(caps.OK, "capabilities should succeed"); err != nil {
		return err
	}
	if err := expect(resultOf(caps)["core"] == coreLinked, "capabilities.core must match the build"); err != nil {
		return err
	}
	tun, _ := resultOf(caps)["tun"].(bool)
	if err := expect(!tun, "windows shell must report tun=false until D-04 is decided"); err != nil {
		return err
	}

	start := server.Handle(request{ID: "2", Method: "service.start", Args: map[string]any{"revision": float64(1), "mode": "proxy"}})
	if err := expect(start.OK, "start should ack"); err != nil {
		return err
	}
	state := ""
	status := server.Handle(request{ID: "3", Method: "service.status"})
	state, _ = resultOf(status)["state"].(string)
	if err := expect(state != stateRunning, fmt.Sprintf("ack must not read as running (got %s)", state)); err != nil {
		return err
	}

	server.sm.runtimeReport(true, 0)
	status = server.Handle(request{ID: "4", Method: "service.status"})
	state, _ = resultOf(status)["state"].(string)
	if err := expect(state == stateRunning, "runtime evidence should make it running"); err != nil {
		return err
	}

	stop := server.Handle(request{ID: "5", Method: "service.stop", Args: map[string]any{"revision": float64(2)}})
	if err := expect(stop.OK, "stop should ack"); err != nil {
		return err
	}
	server.sm.runtimeReport(false, 0)
	if err := expect(server.sm.state == stateIdle, "stop plus evidence should settle idle"); err != nil {
		return err
	}

	validConfig := []byte(`{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`)
	invalidConfig := []byte(`{"outbounds":[{"type":"definitely-not-a-protocol"}]}`)
	if coreLinked {
		check := server.Handle(request{ID: "6", Method: "config.check", Args: map[string]any{"content": encodeBase64(validConfig)}})
		if err := expect(check.OK, "linked core must accept a valid config"); err != nil {
			return err
		}
		bad := server.Handle(request{ID: "6b", Method: "config.check", Args: map[string]any{"content": encodeBase64(invalidConfig)}})
		if err := expect(!bad.OK && bad.Error.Code == "core_rejected_config", "linked core must reject an invalid config"); err != nil {
			return err
		}
	} else {
		check := server.Handle(request{ID: "6", Method: "config.check", Args: map[string]any{"content": encodeBase64(validConfig)}})
		if err := expect(!check.OK && check.Error.Code == "unsupported_platform", "unlinked core must answer unsupported_platform"); err != nil {
			return err
		}
	}

	write := server.Handle(request{ID: "7", Method: "profile.write", Args: map[string]any{
		"label":   "demo",
		"kind":    "local",
		"content": encodeBase64([]byte(`{"log":{"level":"info"}}`)),
	}})
	if err := expect(write.OK, "profile write should succeed"); err != nil {
		return err
	}
	written := resultOf(write)
	id, _ := written["id"].(string)
	read := server.Handle(request{ID: "8", Method: "profile.read", Args: map[string]any{"id": id}})
	if err := expect(read.OK, "profile read should succeed"); err != nil {
		return err
	}
	if err := expect(resultOf(read)["revision"] == written["revision"], "revision should round trip"); err != nil {
		return err
	}
	updated := server.Handle(request{ID: "10", Method: "profile.write", Args: map[string]any{
		"id":               id,
		"label":            "demo",
		"kind":             "local",
		"content":          encodeBase64([]byte(`{"x":1}`)),
		"expectedRevision": written["revision"],
	}})
	if err := expect(updated.OK, "second write should succeed"); err != nil {
		return err
	}
	restore := server.Handle(request{ID: "11", Method: "profile.restore", Args: map[string]any{
		"id":       id,
		"revision": written["revision"],
	}})
	if err := expect(restore.OK, "restore should swap the previous revision back"); err != nil {
		return err
	}
	if err := expect(resultOf(restore)["revision"] == written["revision"], "restore revision should match"); err != nil {
		return err
	}
	unknown := server.Handle(request{ID: "9", Method: "nope.nothing"})
	if err := expect(!unknown.OK && unknown.Error.Code == "unsupported_platform", "unknown method must answer unsupported_platform"); err != nil {
		return err
	}
	fmt.Printf("checks: %d\n", checks)
	return nil
}
