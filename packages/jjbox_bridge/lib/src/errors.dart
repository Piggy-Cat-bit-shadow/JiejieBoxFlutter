/// The error vocabulary of `OUTPUT/CONTRACTS/platform_bridge.contract.json`.
///
/// The wire names are snake_case strings; the enum keeps the mapping in one
/// place so Dart, Kotlin, Swift and C++ can be generated from the same table.
library;

/// The five classes an A-side page renders copy for.
enum AppErrorClass { invalidConfig, unsupported, timeout, io, internal }

/// One bridge error code with its retryability and A-class projection.
enum HostErrorCode {
  invalidArgument('invalid_argument', false, AppErrorClass.invalidConfig),
  unsupportedPlatform('unsupported_platform', false, AppErrorClass.unsupported),
  permissionDenied('permission_denied', true, AppErrorClass.io),
  permissionMissing('permission_missing', true, AppErrorClass.io),
  coreUnavailable('core_unavailable', true, AppErrorClass.io),
  coreBusy('core_busy', true, AppErrorClass.io),
  coreRejectedConfig(
    'core_rejected_config',
    false,
    AppErrorClass.invalidConfig,
  ),
  providerRefreshUnsupported(
    'provider_refresh_unsupported',
    false,
    AppErrorClass.unsupported,
  ),
  providerRefreshFailed('provider_refresh_failed', true, AppErrorClass.io),
  storageWriteFailed('storage_write_failed', true, AppErrorClass.io),
  storageCorrupt('storage_corrupt', false, AppErrorClass.io),
  revisionMismatch('revision_mismatch', true, AppErrorClass.invalidConfig),
  transportDisconnected('transport_disconnected', true, AppErrorClass.io),
  timeout('timeout', true, AppErrorClass.timeout),
  cancelled('cancelled', true, AppErrorClass.timeout),
  closed('closed', false, AppErrorClass.internal),
  internal('internal', false, AppErrorClass.internal),
  configFindings('config_findings', false, AppErrorClass.invalidConfig),
  coreStartFailed('core_start_failed', true, AppErrorClass.internal),
  unsupported('unsupported', false, AppErrorClass.unsupported);

  const HostErrorCode(this.wireName, this.retryable, this.appClass);

  final String wireName;
  final bool retryable;
  final AppErrorClass appClass;

  static HostErrorCode? tryParse(String? wireName) {
    if (wireName == null) {
      return null;
    }
    for (final HostErrorCode code in HostErrorCode.values) {
      if (code.wireName == wireName) {
        return code;
      }
    }
    return null;
  }

  /// Unknown codes become [HostErrorCode.internal] so a newer host cannot crash
  /// an older app; the original string stays in [HostError.wireCode].
  static HostErrorCode parseOrInternal(String? wireName) {
    return tryParse(wireName) ?? HostErrorCode.internal;
  }
}

/// A typed bridge failure carried in the `error` field of a response.
class HostError implements Exception {
  const HostError({
    required this.code,
    required this.message,
    required this.retryable,
    this.details = const <String, Object?>{},
    this.wireCode,
  });

  factory HostError.fromJson(Map<String, Object?> json) {
    final String? rawCode = json['code'] as String?;
    final HostErrorCode code = HostErrorCode.parseOrInternal(rawCode);
    final Map<String, Object?> details =
        (json['details'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return HostError(
      code: code,
      message: json['message'] as String? ?? code.wireName,
      retryable: json['retryable'] as bool? ?? code.retryable,
      details: details,
      wireCode: rawCode == code.wireName ? null : rawCode,
    );
  }

  final HostErrorCode code;
  final String message;
  final bool retryable;
  final Map<String, Object?> details;

  /// Set when the host sent a code this build does not know.
  final String? wireCode;

  String get wireName => wireCode ?? code.wireName;

  AppErrorClass get appClass => code.appClass;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': wireName,
    'message': message,
    'retryable': retryable,
    'details': details,
  };

  @override
  String toString() => 'HostError($wireName, $message)';
}
