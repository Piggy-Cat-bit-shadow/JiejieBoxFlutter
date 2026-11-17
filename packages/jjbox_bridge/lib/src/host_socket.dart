/// A real transport: newline-delimited JSON over a loopback socket.
///
/// Used by the Windows end-to-end test to talk to the actual `core_host` process
/// instead of a fake. Frames with an `id` are responses, frames with a `type` are
/// events; that is the whole demultiplexing rule.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'envelope.dart';
import 'errors.dart';
import 'host_bridge.dart';

class SocketHostTransport implements HostTransport {
  SocketHostTransport._(this._host, this._port, this._socket) {
    _attach(_socket);
  }

  static Future<SocketHostTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // ignore: close_sinks - the socket is closed in dispose()/reconnect()
    final Socket socket = await _open(host, port, timeout);
    return SocketHostTransport._(host, port, socket);
  }

  static Future<Socket> _open(String host, int port, Duration timeout) async {
    // ignore: close_sinks - closed in dispose()
    final Socket socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return socket;
  }

  final String _host;
  final int _port;
  Socket _socket;
  late StreamSubscription<String> _subscription;

  String get endpoint => '$_host:$_port';

  /// Re-establishes the connection to the same endpoint.
  ///
  /// Pending calls fail with `transport_disconnected` (their effect is unknown, so
  /// the caller must re-read `service.status`); the event stream survives, which is
  /// what lets a reconnect stay transparent to the UI.
  Future<void> reconnect({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _failPending(
      const HostError(
        code: HostErrorCode.transportDisconnected,
        message: 'reconnecting',
        retryable: true,
      ),
    );
    await _subscription.cancel();
    await _socket.close();
    _socket = await _openWithRetry(timeout);
    _attach(_socket);
  }

  /// A restarted host may still be closing its old listener, so a reconnect keeps
  /// trying for the whole timeout instead of failing on the first refusal.
  Future<Socket> _openWithRetry(Duration timeout) async {
    final DateTime deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await _open(_host, _port, const Duration(seconds: 1));
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw HostError(
      code: HostErrorCode.transportDisconnected,
      message: 'reconnect failed: $lastError',
      retryable: true,
    );
  }

  void _attach(Socket socket) {
    // A reset connection surfaces through `done` as well; without this the error
    // would escape as an unhandled zone error instead of a typed bridge failure.
    unawaited(socket.done.catchError((Object _) {}));
    _subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: _onError, onDone: _onDone);
  }

  final Map<String, Completer<HostResponse>> _pending =
      <String, Completer<HostResponse>>{};
  final StreamController<HostCallback> _events =
      StreamController<HostCallback>.broadcast();
  bool _closed = false;

  @override
  Stream<HostCallback> get callbacks => _events.stream;

  @override
  Future<HostResponse> send(HostRequest request) async {
    if (_closed) {
      return Future<HostResponse>.error(
        const HostError(
          code: HostErrorCode.transportDisconnected,
          message: 'socket is closed',
          retryable: true,
        ),
      );
    }
    final Completer<HostResponse> completer = Completer<HostResponse>();
    _pending[request.id] = completer;
    try {
      _socket.write('${jsonEncode(request.toJson())}\n');
      // Flushing turns a dead connection into an awaited error instead of an
      // unhandled async error on the socket's sink.
      await _socket.flush();
    } catch (error) {
      _pending.remove(request.id);
      return Future<HostResponse>.error(
        HostError(
          code: HostErrorCode.transportDisconnected,
          message: '$error',
          retryable: true,
        ),
      );
    }
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(request.id);
        throw const HostError(
          code: HostErrorCode.timeout,
          message: 'the host did not answer on the socket',
          retryable: true,
        );
      },
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    final Object? decoded = jsonDecode(line);
    if (decoded is! Map<Object?, Object?>) {
      return;
    }
    final Map<String, Object?> frame = decoded.cast<String, Object?>();
    final Object? id = frame['id'];
    if (id is String) {
      final Completer<HostResponse>? completer = _pending.remove(id);
      completer?.complete(HostResponse.fromJson(frame));
      return;
    }
    final Object? type = frame['type'];
    if (type is String && !_events.isClosed) {
      _events.add(HostCallback.fromJson(frame));
    }
  }

  void _onError(Object error) {
    _failPending(
      HostError(
        code: HostErrorCode.transportDisconnected,
        message: '$error',
        retryable: true,
      ),
    );
  }

  void _onDone() {
    _failPending(
      const HostError(
        code: HostErrorCode.transportDisconnected,
        message: 'the host closed the socket',
        retryable: true,
      ),
    );
  }

  void _failPending(HostError error) {
    for (final Completer<HostResponse> completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }

  @override
  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription.cancel();
    await _socket.close();
    await _events.close();
  }
}
