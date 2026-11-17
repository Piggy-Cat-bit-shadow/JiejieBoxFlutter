/// The single built-in default configuration.
///
/// Deliberately minimal and platform-neutral: no B-box DNS/direct/UDP-443/853/
/// STUN policy, no TUN address pinned to Android, no MTU 9000. Every value is
/// a sing-box schema field; turning this into a running config still requires
/// the kernel's `CheckConfig` (CONTRACTS K1), which this build cannot call.
///
/// The import UI marks drafts created from it as **unvalidated**.
const defaultConfigTemplate = '''
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [{ "tag": "local", "type": "local" }],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct", "auto_detect_interface": true }
}
''';

/// A label that does not collide with an existing profile.
String defaultTemplateLabel(int existingCount) =>
    existingCount == 0 ? 'Default' : 'Default ${existingCount + 1}';
