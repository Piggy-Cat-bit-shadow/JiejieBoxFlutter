/// A scriptable in-memory host used by every bridge test.
///
/// It implements the same envelope, the same 24 methods and the same state
/// machine as the native hosts, so a passing test here is a statement about the
/// contract rather than about a mock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../capabilities.dart';
import '../envelope.dart';
import '../errors.dart';
import '../host_bridge.dart';
import '../service_state.dart';
import '../sha256.dart';

class FakeHost implements HostTransport {
  FakeHost({
    bool tun = false,
    bool systemProxy = false,
    bool desktop = false,
    bool requestPermission = false,
    PermissionEvidence permission = PermissionEvidence.granted,
    CoreCapabilities? core,
    DateTime Function()? clock,
  })  : _capabilities = <String, Object?>{
          'tun': tun,
          'systemProxy': systemProxy,
          'perAppProxy': false,
          'autostart': desktop,
          'tray': desktop,
          'qrCamera': !desktop,
          'qrImageDecode': true,
          'fileImport': true,
          'clipboardWatch': true,
          'notifications': true,
          'deepLink': true,
          'memoryPressure': !desktop,
          'serviceModes': tun ? <String>['vpn', 'proxy'] : <String>['proxy'],
        },
        _needsPermission = requestPermission,
        _core = core ??
            const CoreCapabilities(
              apiVersion: 4,
              buildId: 'fake-build',
              buildQuic: true,
              platform: 'test',
              version: '0.1.0',
              goVersion: 'go1.27.4',
              types: <String>['direct', 'vless', 'hysteria2', 'tuic'],
            ),
        _clock = clock ?? DateTime.now {
    machine = HostServiceStateMachine(permission: permission);
  }

  final Map<String, Object?> _capabilities;
  final bool _needsPermission;
  final CoreCapabilities _core;
  final DateTime Function() _clock;

  late final HostServiceStateMachine machine;

  final List<HostRequest> received = <HostRequest>[];
  final Map<String, Uint8List> profiles = <String, Uint8List>{};
  final Map<String, String> revisions = <String, String>{};
  final Map<String, Uint8List> restorePoints = <String, Uint8List>{};
  final Map<String, String> restoreRevisions = <String, String>{};
  final Set<String> corruptProfiles = <String>{};

  /// Set false to exercise the core's `supported:false` capability answer.
  bool providerRefreshSupported = true;

  final StreamController<HostCallback> _callbacks =
      StreamController<HostCallback>.broadcast();
  final Map<String, HostErrorCode> _failNext = <String, HostErrorCode>{};
  final Map<String, Duration> _delayNext = <String, Duration>{};

  int _seq = 0;
  int _since = 0;

  /// Queue a typed failure for the next call of [method].
  void failNext(String method, HostErrorCode code) {
    _failNext[method] = code;
  }

  /// Delay the next call of [method] (used to exercise bridge timeouts).
  void delayNext(String method, Duration delay) {
    _delayNext[method] = delay;
  }

  /// Push runtime evidence; the state machine decides what it means.
  void reportRuntime(RuntimeEvidence evidence, {int revision = 0}) {
    machine.runtimeReport(evidence, revision: revision);
    _emit('service.state', _status());
  }

  void reportPermission(PermissionEvidence evidence) {
    machine.permissionReport(evidence);
    _emit('permission.changed', <String, Object?>{
      'kind': 'vpn',
      'status': evidence.name,
    });
  }

  void emitRaw(String type, Map<String, Object?> data) => _emit(type, data);

  void _emit(String type, Map<String, Object?> data) {
    if (_callbacks.isClosed) {
      return;
    }
    _seq += 1;
    _callbacks.add(HostCallback(type: type, seq: _seq, data: data));
  }

  @override
  Stream<HostCallback> get callbacks => _callbacks.stream;

  @override
  Future<HostResponse> send(HostRequest request) async {
    received.add(request);
    final Duration? delay = _delayNext.remove(request.method);
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    final HostErrorCode? injected = _failNext.remove(request.method);
    if (injected != null) {
      return HostResponse(
        id: request.id,
        error: HostError(
          code: injected,
          message: 'injected ${injected.wireName}',
          retryable: injected.retryable,
        ),
      );
    }
    try {
      final Map<String, Object?> result = _handle(request);
      return HostResponse(id: request.id, result: result);
    } on HostError catch (error) {
      return HostResponse(id: request.id, error: error);
    }
  }

  Map<String, Object?> _handle(HostRequest request) {
    final Map<String, Object?> args = request.args;
    switch (request.method) {
      case BridgeMethod.hostCapabilities:
        return _capabilities;
      case BridgeMethod.coreCapabilities:
        return _core.toJson();
      case BridgeMethod.hostSetup:
        return const <String, Object?>{};
      case BridgeMethod.hostShutdown:
        return const <String, Object?>{};
      case BridgeMethod.serviceStart:
        final int revision = (args['revision'] as num?)?.toInt() ?? 0;
        final String mode = args['mode'] as String? ?? 'proxy';
        final String outcome = machine.start(
          revision,
          needsPermission: _needsPermission && mode == 'vpn',
        );
        if (outcome == 'pending') {
          _emit('service.state', _status());
        }
        return <String, Object?>{'accepted': outcome != 'rejected:closed', 'revision': revision};
      case BridgeMethod.serviceStop:
        final int revision = (args['revision'] as num?)?.toInt() ?? 0;
        final String outcome = machine.stop(revision);
        if (outcome == 'pending') {
          _emit('service.state', _status());
        }
        return <String, Object?>{'accepted': outcome != 'rejected:closed', 'revision': revision};
      case BridgeMethod.serviceStatus:
        return _status();
      case BridgeMethod.configCheck:
        final String content = args['content'] as String? ?? '';
        final bool ok = content.isNotEmpty;
        return <String, Object?>{
          'ok': ok,
          'normalizedKind': ok ? 'singbox-json' : null,
          'code': ok ? null : 'invalid_argument',
          'message': ok ? null : 'empty content',
        };
      case BridgeMethod.configFormat:
        return <String, Object?>{'content': args['content']};
      case BridgeMethod.configPreview:
        return <String, Object?>{
          'ok': true,
          'format': 'links',
          'count': 2,
          'declared': 3,
          'base64': false,
          'items': <Object?>[
            <String, Object?>{'tag': 'a', 'type': 'vless', 'endpoint': false},
            <String, Object?>{'tag': 'b', 'type': 'hysteria2', 'endpoint': false},
          ],
          'skipped': <Object?>[
            <String, Object?>{'line': 3, 'reason': 'unsupported scheme: ssr'},
          ],
        };
      case BridgeMethod.profileList:
        return <String, Object?>{
          'items': <Object?>[
            for (final String id in profiles.keys)
              <String, Object?>{
                'id': id,
                'label': id,
                'kind': 'local',
                'revision': revisions[id],
                'bytes': profiles[id]!.length,
              },
          ],
        };
      case BridgeMethod.profileRead:
        final String id = args['id'] as String? ?? '';
        if (corruptProfiles.contains(id)) {
          throw HostError(
            code: HostErrorCode.storageCorrupt,
            message: 'stored profile $id cannot be parsed',
            retryable: false,
            details: <String, Object?>{'id': id},
          );
        }
        final Uint8List? content = profiles[id];
        if (content == null) {
          throw const HostError(
            code: HostErrorCode.invalidArgument,
            message: 'no such profile',
            retryable: false,
          );
        }
        return <String, Object?>{
          'id': id,
          'content': base64Encode(content),
          'revision': revisions[id],
        };
      case BridgeMethod.profileWrite:
        final String? id = args['id'] as String?;
        final String? expected = args['expectedRevision'] as String?;
        final Uint8List content =
            base64Decode(args['content'] as String? ?? '');
        final String target = id ?? 'p${profiles.length + 1}';
        if (expected != null && revisions[target] != expected) {
          throw const HostError(
            code: HostErrorCode.revisionMismatch,
            message: 'expectedRevision mismatch',
            retryable: true,
          );
        }
        final Uint8List? previousBody = profiles[target];
        final String? previousRevision = revisions[target];
        if (previousBody != null && previousRevision != null) {
          restorePoints[target] = previousBody;
          restoreRevisions[target] = previousRevision;
        }
        profiles[target] = content;
        revisions[target] = sha256Hex(content).substring(0, 16);
        return <String, Object?>{
          'id': target,
          'revision': revisions[target],
          'bytes': content.length,
          'validated': args['validate'] as bool? ?? true,
        };
      case BridgeMethod.profileRestore:
        final String id = args['id'] as String? ?? '';
        final String revision = args['revision'] as String? ?? '';
        if (revisions[id] == revision) {
          return <String, Object?>{'id': id, 'revision': revision};
        }
        final Uint8List? body = restorePoints[id];
        if (body == null || restoreRevisions[id] != revision) {
          throw const HostError(
            code: HostErrorCode.revisionMismatch,
            message: 'no retained revision to restore',
            retryable: true,
          );
        }
        profiles[id] = body;
        revisions[id] = revision;
        return <String, Object?>{
          'id': id,
          'revision': revision,
          'bytes': body.length,
          'validated': true,
        };
      case BridgeMethod.profileDelete:
        final String id = args['id'] as String? ?? '';
        profiles.remove(id);
        revisions.remove(id);
        return const <String, Object?>{};
      case BridgeMethod.profileApply:
        // `revision` is the content revision string; the machine wants its own
        // monotonically increasing intent revision.
        final String outcome = machine.start(machine.revision + 1);
        _emit('service.state', _status());
        return <String, Object?>{
          'applied': outcome != 'rejected:closed',
          'requestId': args['requestId'],
        };
      case BridgeMethod.providerRefresh:
        final List<Object?> tags =
            (args['tags'] as List<Object?>?) ?? const <Object?>[];
        return <String, Object?>{
          'supported': providerRefreshSupported,
          'refreshed': tags,
          'failed': const <Object?>[],
          'durationMillis': 12,
        };
      case BridgeMethod.systemProxyApply:
        return <String, Object?>{
          'enabled': args['enabled'] ?? false,
          'applied': _capabilities['systemProxy'] as bool? ?? false,
        };
      case BridgeMethod.systemProxyStatus:
        return <String, Object?>{
          'ourProxyActive': false,
          'staleFromPreviousRun': false,
        };
      case BridgeMethod.tunRequestPermission:
        return <String, Object?>{
          'status': _needsPermission ? 'denied' : 'granted',
          'asked': _needsPermission,
        };
      case BridgeMethod.qrScan:
        return <String, Object?>{'text': 'vless://example@host:443#demo'};
      case BridgeMethod.filePickConfig:
        return <String, Object?>{
          'name': 'config.json',
          'content': base64Encode(Uint8List.fromList(utf8.encode('{"log":{}}'))),
          'sha256': 'fake-sha',
        };
      case BridgeMethod.clipboardReadCandidate:
        return <String, Object?>{
          'text': 'vless://example@host:443#demo',
          'likely': 'share-link',
        };
      case BridgeMethod.appSetAutoLaunch:
        return <String, Object?>{'enabled': args['enabled'] ?? false};
      case BridgeMethod.trayUpdate:
        return const <String, Object?>{};
      default:
        throw HostError(
          code: HostErrorCode.unsupportedPlatform,
          message: 'unknown method ${request.method}',
          retryable: false,
        );
    }
  }

  Map<String, Object?> _status() => <String, Object?>{
        'state': machine.state.name,
        'revision': machine.revision,
        'sinceMillis': _since++,
        'mode': 'proxy',
        'tunActive': machine.state == ServiceState.running,
        'proxyPort': 7890,
        'permission': machine.state == ServiceState.awaitingPermission
            ? 'denied'
            : 'granted',
      };

  @override
  Future<void> dispose() async {
    await _callbacks.close();
  }

  DateTime now() => _clock();
}
