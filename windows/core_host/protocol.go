package main

// The wire vocabulary of OUTPUT/CONTRACTS/platform_bridge.contract.json.
// Codes are strings on purpose: a Go enum would have to be mapped back at the
// boundary anyway, and the contract is the single source.

type bridgeError struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	Retryable bool           `json:"retryable"`
	Details   map[string]any `json:"details,omitempty"`
}

func (e *bridgeError) Error() string { return e.Code + ": " + e.Message }

var (
	errUnsupportedPlatform = func(what string) *bridgeError {
		return &bridgeError{
			Code:      "unsupported_platform",
			Message:   what + " is not available on this platform",
			Retryable: false,
		}
	}
	errCoreUnavailable = &bridgeError{
		Code:      "core_unavailable",
		Message:   "the Go core is not linked into this build",
		Retryable: true,
	}
	errInvalidArgument = func(what string) *bridgeError {
		return &bridgeError{Code: "invalid_argument", Message: what, Retryable: false}
	}
	errRevisionMismatch = &bridgeError{
		Code:      "revision_mismatch",
		Message:   "expectedRevision does not match the stored revision",
		Retryable: true,
	}
	errStorageWriteFailed = func(what string) *bridgeError {
		return &bridgeError{Code: "storage_write_failed", Message: what, Retryable: true}
	}
	errStorageCorrupt = func(id string) *bridgeError {
		return &bridgeError{
			Code:      "storage_corrupt",
			Message:   "stored profile " + id + " cannot be parsed",
			Retryable: false,
			Details:   map[string]any{"id": id},
		}
	}
)

type request struct {
	ID     string         `json:"id"`
	Method string         `json:"method"`
	Args   map[string]any `json:"args"`
}

type response struct {
	ID     string       `json:"id"`
	OK     bool         `json:"ok"`
	Result any          `json:"result,omitempty"`
	Error  *bridgeError `json:"error,omitempty"`
}

func ok(id string, result any) response { return response{ID: id, OK: true, Result: result} }

func fail(id string, err *bridgeError) response {
	return response{ID: id, OK: false, Error: err}
}

// argContent decodes the base64 payload every config.* call carries. The bridge
// encodes bytes on the wire, so passing the raw argument to libbox would make every
// document look like malformed JSON.
func argContent(args map[string]any) (string, *bridgeError) {
	raw := argString(args, "content")
	if raw == "" {
		return "", errInvalidArgument("content is required")
	}
	decoded, err := decodeBase64(raw)
	if err != nil {
		return "", errInvalidArgument("content must be base64")
	}
	return string(decoded), nil
}

func argString(args map[string]any, key string) string {
	if args == nil {
		return ""
	}
	if value, found := args[key].(string); found {
		return value
	}
	return ""
}

func argInt(args map[string]any, key string) int64 {
	if args == nil {
		return 0
	}
	switch value := args[key].(type) {
	case float64:
		return int64(value)
	case int64:
		return value
	case int:
		return int64(value)
	}
	return 0
}

func argBool(args map[string]any, key string, fallback bool) bool {
	if args == nil {
		return fallback
	}
	if value, found := args[key].(bool); found {
		return value
	}
	return fallback
}
