/// Clipboard promotion gate.
///
/// A clipboard payload is never saved on its own: the app must be foreground and
/// the read must come from an explicit user action, and the same payload is only
/// offered once per window. The gate is pure so every platform test can drive it.
library;

enum ClipboardDecision {
  accept,
  empty,
  notUserInitiated,
  background,
  duplicate,
}

class ClipboardGate {
  ClipboardGate({
    this.dedupeWindow = const Duration(seconds: 30),
  });

  final Duration dedupeWindow;

  String? _lastSha;
  DateTime? _lastSeen;

  ClipboardDecision evaluate({
    required bool userInitiated,
    required bool foreground,
    required String text,
    required DateTime now,
    String? sha256,
  }) {
    if (!userInitiated) {
      return ClipboardDecision.notUserInitiated;
    }
    if (!foreground) {
      return ClipboardDecision.background;
    }
    if (text.trim().isEmpty) {
      return ClipboardDecision.empty;
    }
    final String digest = sha256 ?? text.trim();
    final DateTime? seen = _lastSeen;
    if (_lastSha == digest && seen != null && now.difference(seen) < dedupeWindow) {
      return ClipboardDecision.duplicate;
    }
    _lastSha = digest;
    _lastSeen = now;
    return ClipboardDecision.accept;
  }

  void reset() {
    _lastSha = null;
    _lastSeen = null;
  }
}
