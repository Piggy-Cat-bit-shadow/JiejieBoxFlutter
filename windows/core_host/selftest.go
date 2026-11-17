package main

import (
	"errors"
	"fmt"
)

// runSelfTest drives the host the way the Dart bridge does. It is deliberately
// tied to the real dispatcher and core seam: the linked build proves a real
// service start/stop and profile apply; the default build proves the honest
// unsupported answers. No test hook is used here.
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
	if err := expect(caps.OK, "capabilities should succeed"); err != nil {
		return err
	}
	capsResult := resultOf(caps)
	if err := expect(capsResult["core"] == coreLinked, "capabilities.core must match the build"); err != nil {
		return err
	}
	for _, key := range []string{"tun", "systemProxy", "autostart", "tray", "events"} {
		if err := expect(capsResult[key] == false, "capability "+key+" must be false"); err != nil {
			return err
		}
	}
	if err := expect(capsResult["qrImageDecode"] == false, "Windows must not claim QR image decoding"); err != nil {
		return err
	}
	proxyApply := server.Handle(request{ID: "2", Method: "systemProxy.apply", Args: map[string]any{"enabled": true}})
	if err := expect(!proxyApply.OK && proxyApply.Error.Code == "unsupported_platform",
		"systemProxy.apply must be unsupported when the capability is false"); err != nil {
		return err
	}

	config := `{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`
	invalid := `{"outbounds":[{"type":"definitely-not-a-protocol"}]}`
	if coreLinked {
		check := server.Handle(request{ID: "3", Method: "config.check", Args: map[string]any{"content": encodeBase64([]byte(config))}})
		if err := expect(check.OK, "linked core must accept a valid config"); err != nil {
			return err
		}
		bad := server.Handle(request{ID: "4", Method: "config.check", Args: map[string]any{"content": encodeBase64([]byte(invalid))}})
		if err := expect(!bad.OK && bad.Error.Code == "core_rejected_config", "linked core must reject an invalid config"); err != nil {
			return err
		}
	} else {
		check := server.Handle(request{ID: "3", Method: "config.check", Args: map[string]any{"content": encodeBase64([]byte(config))}})
		if err := expect(!check.OK && check.Error.Code == "unsupported_platform", "unlinked core must answer unsupported_platform"); err != nil {
			return err
		}
	}

	write := server.Handle(request{ID: "5", Method: "profile.write", Args: map[string]any{
		"label": "demo", "kind": "local", "content": encodeBase64([]byte(config)),
	}})
	if err := expect(write.OK, "profile write should succeed"); err != nil {
		return err
	}
	written := resultOf(write)
	id, _ := written["id"].(string)
	revision, _ := written["revision"].(string)
	read := server.Handle(request{ID: "6", Method: "profile.read", Args: map[string]any{"id": id}})
	if err := expect(read.OK && resultOf(read)["revision"] == revision, "profile revision should round trip"); err != nil {
		return err
	}

	missing := server.Handle(request{ID: "7", Method: "profile.apply", Args: map[string]any{
		"id": "DOES_NOT_EXIST", "revision": "nope", "requestId": "selftest-missing", "mode": "proxy",
	}})
	if err := expect(!missing.OK && missing.Error.Code == "profile_not_found",
		"profile.apply must not succeed for a missing profile"); err != nil {
		return err
	}

	start := server.Handle(request{ID: "8", Method: "service.start", Args: map[string]any{
		"revision": float64(1), "mode": "proxy", "profileId": id, "profileRevision": revision,
	}})
	if coreLinked {
		if err := expect(start.OK, "linked host should start a real service"); err != nil {
			return err
		}
		status := server.Handle(request{ID: "9", Method: "service.status"})
		if err := expect(resultOf(status)["state"] == stateRunning, "service.status must report running after a real start"); err != nil {
			return err
		}
		duplicate := server.Handle(request{ID: "10", Method: "service.stop", Args: map[string]any{"revision": float64(1)}})
		if err := expect(!duplicate.OK && duplicate.Error.Code == "stale_revision", "stale stop must be rejected"); err != nil {
			return err
		}
		stop := server.Handle(request{ID: "11", Method: "service.stop", Args: map[string]any{"revision": float64(2)}})
		if err := expect(stop.OK, "linked host should stop the real service"); err != nil {
			return err
		}
		status = server.Handle(request{ID: "12", Method: "service.status"})
		if err := expect(resultOf(status)["state"] == stateIdle, "service.status must settle idle after stop"); err != nil {
			return err
		}
		apply := server.Handle(request{ID: "13", Method: "profile.apply", Args: map[string]any{
			"id": id, "revision": revision, "requestId": "selftest-apply", "mode": "proxy",
		}})
		if err := expect(apply.OK, "linked host should apply a real profile"); err != nil {
			return err
		}
		stop = server.Handle(request{ID: "14", Method: "service.stop", Args: map[string]any{"revision": float64(4)}})
		if err := expect(stop.OK, "stop after apply should succeed"); err != nil {
			return err
		}
		badWrite := server.Handle(request{ID: "7b", Method: "profile.write", Args: map[string]any{
			"label": "bad", "kind": "local", "content": encodeBase64([]byte(invalid)),
		}})
		if err := expect(badWrite.OK, "invalid profile should still be storable for the negative apply test"); err != nil {
			return err
		}
		badMeta := resultOf(badWrite)
		badApply := server.Handle(request{ID: "13b", Method: "profile.apply", Args: map[string]any{
			"id": badMeta["id"], "revision": badMeta["revision"], "requestId": "selftest-bad", "mode": "proxy",
		}})
		if err := expect(!badApply.OK && badApply.Error.Code == "core_rejected_config",
			"profile.apply must fail for an invalid document"); err != nil {
			return err
		}
		if err := expect(!server.core.Running(), "invalid apply must not leave a service running"); err != nil {
			return err
		}
	} else {
		if err := expect(!start.OK && start.Error.Code == "unsupported_platform",
			"unlinked host must not claim it started a service"); err != nil {
			return err
		}
	}

	unknown := server.Handle(request{ID: "15", Method: "nope.nothing"})
	if err := expect(!unknown.OK && unknown.Error.Code == "unsupported_platform", "unknown method must answer unsupported_platform"); err != nil {
		return err
	}
	if err := expect(server.core.Running() == false, "selftest must leave the core stopped"); err != nil {
		return err
	}
	fmt.Printf("checks: %d\n", checks)
	return nil
}
