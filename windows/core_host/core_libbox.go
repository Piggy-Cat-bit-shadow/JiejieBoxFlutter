//go:build libbox

package main

import (
	"encoding/base64"
	stdjson "encoding/json"
	"runtime"
	"strings"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// This build links the pinned kernel module (experimental/libbox). It is produced by
// tools/build_core_host_libbox.ps1, which points a throwaway module at a read-only
// kernel checkout with the flutter-api patch applied; the committed go.mod stays
// dependency-free so the default host build keeps working without a kernel tree.
//
// TUN stays out on Windows: libbox's OpenInterface fails at dup/getTunnelName, so the
// host still advertises tun:false and only proxy mode is offered.

const coreLinked = true

type linkedCore struct{}

func defaultCore() coreAPI { return linkedCore{} }

func (linkedCore) Capabilities() map[string]any {
	return map[string]any{
		"apiVersion":   4,
		"buildId":      nil,
		"buildQuic":    true,
		"platform":     "windows",
		"version":      libbox.Version(),
		"goVersion":    runtime.Version(),
		"capabilities": []map[string]any{},
	}
}

// sanitizeCoreError keeps a core parse error useful without echoing document content.
// Credentials live in node documents, so the text is stripped of newlines, truncated and
// never includes the original config.
func sanitizeCoreError(err error) string {
	text := strings.Join(strings.Fields(err.Error()), " ")
	if len(text) > 300 {
		text = text[:300]
	}
	return text
}

func (linkedCore) CheckConfig(content string) (map[string]any, *bridgeError) {
	if err := libbox.CheckConfig(content); err != nil {
		return nil, &bridgeError{
			Code:      "core_rejected_config",
			Message:   sanitizeCoreError(err),
			Retryable: false,
			Details:   map[string]any{"coreText": sanitizeCoreError(err)},
		}
	}
	return map[string]any{"ok": true, "normalizedKind": "singbox-json"}, nil
}

func (linkedCore) FormatConfig(content string) (map[string]any, *bridgeError) {
	formatted, err := libbox.FormatConfig(content)
	if err != nil {
		return nil, &bridgeError{
			Code:      "core_rejected_config",
			Message:   sanitizeCoreError(err),
			Retryable: false,
			Details:   map[string]any{"coreText": sanitizeCoreError(err)},
		}
	}
	return map[string]any{"content": base64.StdEncoding.EncodeToString([]byte(formatted.Value))}, nil
}

func (linkedCore) Preview(content string) (map[string]any, *bridgeError) {
	preview, err := libbox.ParsePreview(content)
	if err != nil {
		return nil, &bridgeError{
			Code:      "invalid_argument",
			Message:   sanitizeCoreError(err),
			Retryable: false,
		}
	}
	var report map[string]any
	if err := stdjson.Unmarshal([]byte(preview.Value), &report); err != nil {
		return nil, &bridgeError{Code: "internal", Message: "preview decode failed", Retryable: false}
	}
	return report, nil
}

func (linkedCore) Refresh(tags []string, timeoutMillis int64) (map[string]any, *bridgeError) {
	// Refreshing needs a connected CommandClient, i.e. a running service. The shell
	// does not run one yet, so it reports the capability truthfully instead of a
	// fabricated success.
	_ = tags
	_ = timeoutMillis
	return map[string]any{
		"supported":      false,
		"refreshed":      []string{},
		"failed":         map[string]string{},
		"durationMillis": 0,
	}, nil
}
