/// The real transport: two MethodChannels carrying the contract envelope.
///
/// `jjbox/host` is invoked with a JSON string request and answers a JSON string
/// response; `jjbox/host/callback` is a host-to-Dart channel that delivers one
/// callback envelope per message.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'envelope.dart';
import 'errors.dart';
import 'host_bridge.dart';

class MethodChannelHostTransport implements HostTransport {
  MethodChannelHostTransport({
    MethodChannel commands = const MethodChannel('jjbox/host'),
    MethodChannel callbacks = const MethodChannel('jjbox/host/callback'),
  }) : _commands = commands,
       _callbacks = callbacks {
    _callbacks.setMethodCallHandler(_onCallback);
  }

  final MethodChannel _commands;
  final MethodChannel _callbacks;
  final StreamController<HostCallback> _stream =
      StreamController<HostCallback>.broadcast();

  @override
  Stream<HostCallback> get callbacks => _stream.stream;

  @override
  Future<HostResponse> send(HostRequest request) async {
    final String? raw = await _commands.invokeMethod<String>(
      'jjbox.invoke',
      jsonEncode(request.toJson()),
    );
    if (raw == null || raw.isEmpty) {
      throw HostError(
        code: HostErrorCode.coreUnavailable,
        message: 'The host returned no response for ${request.method}.',
        retryable: true,
      );
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<Object?, Object?>) {
      throw const HostError(
        code: HostErrorCode.internal,
        message: 'Malformed bridge response.',
        retryable: false,
      );
    }
    return HostResponse.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> _onCallback(MethodCall call) async {
    if (call.method != 'event') {
      return;
    }
    final Object? arguments = call.arguments;
    HostCallback? callback;
    if (arguments is String) {
      final Object? decoded = jsonDecode(arguments);
      if (decoded is Map<Object?, Object?>) {
        callback = HostCallback.fromJson(decoded.cast<String, Object?>());
      }
    } else if (arguments is Map<Object?, Object?>) {
      callback = HostCallback.fromJson(arguments.cast<String, Object?>());
    }
    if (callback != null && !_stream.isClosed) {
      _stream.add(callback);
    }
  }

  @override
  Future<void> dispose() async {
    _callbacks.setMethodCallHandler(null);
    await _stream.close();
  }
}
