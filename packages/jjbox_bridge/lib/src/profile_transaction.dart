/// Profile transactions: serialized writes, restore points and switch rollback.
///
/// The host owns bytes and revisions (see the contract's `transaction_model`);
/// this layer only decides *when* a write or a switch may run and what to do when
/// one fails. Nothing here holds a lock across a network call.
library;

import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';
import 'host_bridge.dart';

/// One profile's identity at a revision.
class ProfileRef {
  const ProfileRef(this.id, this.revision);

  final String id;
  final String revision;

  @override
  String toString() => '$id@$revision';
}

/// Serializes every mutating profile call through one queue.
///
/// Reads stay unlocked on purpose: a switch must be able to read the selected
/// profile while a subscription download is finishing, and the host answers a
/// read of a half-written profile with the previous revision, never a torn one.
class ProfileRepository {
  ProfileRepository({required this.bridge});

  final HostBridge bridge;

  Future<void> _tail = Future<void>.value();
  int _queued = 0;

  /// Number of mutating calls queued or running.
  int get queued => _queued;

  bool get idle => _queued == 0;

  Future<T> _serialized<T>(Future<T> Function() action) {
    _queued += 1;
    final Completer<T> completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _queued -= 1;
      }
    });
    return completer.future;
  }

  Future<List<ProfileMeta>> list() => bridge.listProfiles();

  Future<ProfileContent> read(String id) => bridge.readProfile(id);

  Future<ProfileWriteResult> write({
    String? id,
    required String label,
    required String kind,
    required List<int> content,
    String? expectedRevision,
    bool validate = true,
  }) {
    return _serialized(
      () => bridge.writeProfile(
        id: id,
        label: label,
        kind: kind,
        content: _bytes(content),
        expectedRevision: expectedRevision,
        validate: validate,
      ),
    );
  }

  Future<void> delete(String id, {String? expectedRevision}) {
    return _serialized(
      () => bridge.deleteProfile(id, expectedRevision: expectedRevision),
    );
  }

  Future<ProfileWriteResult> restore(String id, String revision) {
    return _serialized(() => bridge.restoreProfile(id, revision));
  }
}

/// What a switch attempt did, so the UI never has to guess.
sealed class SwitchOutcome {
  const SwitchOutcome();
}

class SwitchApplied extends SwitchOutcome {
  const SwitchApplied(this.target);

  final ProfileRef target;
}

class SwitchRejected extends SwitchOutcome {
  const SwitchRejected(this.target, this.error);

  final ProfileRef target;
  final HostError error;
}

class SwitchNoop extends SwitchOutcome {
  const SwitchNoop(this.reason);

  final String reason;
}

/// Applies a profile and keeps the last known good one for recovery.
///
/// A failed apply must leave the previous profile active: the host is expected to
/// answer an ApplyReport with `applied:false` or a typed error, and this class
/// never publishes the new revision in that case.
class ProfileSwitchTransaction {
  ProfileSwitchTransaction({required this.bridge, required this.repository});

  final HostBridge bridge;
  final ProfileRepository repository;

  ProfileRef? _lastGood;

  ProfileRef? get lastGood => _lastGood;

  Future<SwitchOutcome> switchTo({
    required String id,
    required String revision,
    required String requestId,
    String mode = 'vpn',
  }) async {
    final ProfileRef target = ProfileRef(id, revision);
    try {
      final ApplyReport report = await bridge.applyProfile(
        id: id,
        revision: revision,
        requestId: requestId,
        mode: mode,
      );
      if (!report.applied) {
        return SwitchRejected(
          target,
          HostError(
            code: HostErrorCode.coreStartFailed,
            message: report.coreMessage ?? 'the core refused the profile',
            retryable: true,
            details: <String, Object?>{'requestId': report.requestId},
          ),
        );
      }
      _lastGood = target;
      return SwitchApplied(target);
    } on HostError catch (error) {
      return SwitchRejected(target, error);
    }
  }

  /// After a crash or a channel reconnect: if the service is not running but a
  /// known-good profile exists, re-apply it once. Idempotent.
  Future<SwitchOutcome> recover({String requestId = 'recover'}) async {
    final ProfileRef? good = _lastGood;
    if (good == null) {
      return const SwitchNoop('no known good profile');
    }
    final RuntimeStatus status = await bridge.status();
    if (status.isRunning) {
      return const SwitchNoop('already running');
    }
    return switchTo(
      id: good.id,
      revision: good.revision,
      requestId: requestId,
      mode: status.mode.isEmpty ? 'vpn' : status.mode,
    );
  }
}

/// The single shape the transport accepts for profile bytes.
Uint8List _bytes(List<int> content) => Uint8List.fromList(content);
