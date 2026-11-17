/// The request/response/callback envelope of the bridge contract.
library;

import 'errors.dart';

/// `{id, method, args}` as sent on `jjbox/host`.
class HostRequest {
  const HostRequest({
    required this.id,
    required this.method,
    this.args = const <String, Object?>{},
  });

  factory HostRequest.fromJson(Map<String, Object?> json) {
    return HostRequest(
      id: json['id'] as String? ?? '',
      method: json['method'] as String? ?? '',
      args: (json['args'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
          const <String, Object?>{},
    );
  }

  final String id;
  final String method;
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'method': method,
        'args': args,
      };
}

/// `{id, ok, result}` or `{id, ok:false, error}`.
class HostResponse {
  const HostResponse({required this.id, this.result, this.error});

  factory HostResponse.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? errorJson =
        (json['error'] as Map<Object?, Object?>?)?.cast<String, Object?>();
    return HostResponse(
      id: json['id'] as String? ?? '',
      result: json['result'],
      error: errorJson == null ? null : HostError.fromJson(errorJson),
    );
  }

  final String id;
  final Object? result;
  final HostError? error;

  bool get ok => error == null;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'ok': ok,
        'result': result,
        'error': error?.toJson(),
      };

  /// Returns the result map or throws the typed error.
  Map<String, Object?> requireResult() {
    final HostError? failure = error;
    if (failure != null) {
      throw failure;
    }
    final Object? value = result;
    if (value is Map<Object?, Object?>) {
      return value.cast<String, Object?>();
    }
    return const <String, Object?>{};
  }
}

/// `{type, seq, data}` as delivered on `jjbox/host/callback`.
class HostCallback {
  const HostCallback({
    required this.type,
    required this.seq,
    this.data = const <String, Object?>{},
  });

  factory HostCallback.fromJson(Map<String, Object?> json) {
    return HostCallback(
      type: json['type'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      data: (json['data'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
          const <String, Object?>{},
    );
  }

  final String type;
  final int seq;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        'seq': seq,
        'data': data,
      };
}

/// Detects gaps in the callback sequence so Dart can ask for a full resync.
class CallbackSequence {
  int _last = 0;

  /// Returns true when a gap was observed (or this is the first callback and it
  /// does not start at 1).
  bool accept(int seq) {
    if (seq <= _last) {
      return false;
    }
    final bool gap = seq != _last + 1;
    _last = seq;
    return gap;
  }

  int get last => _last;

  void reset([int to = 0]) {
    _last = to;
  }
}
