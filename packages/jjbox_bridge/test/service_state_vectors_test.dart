import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

/// Runs the same acceptance vectors the P0 reference model runs, so the Dart
/// machine and the contract cannot drift apart silently.
void main() {
  final File vectorsFile = File('vectors/lifecycle_vectors.json');

  // The ids are part of the contract: adding, dropping or renaming one is a
  // contract change and must be reviewed, not silently accepted by a green run.
  const List<String> expectedIds = <String>[
    'L01-start-becomes-running-only-on-evidence',
    'L02-double-start-coalesces',
    'L03-stop-during-start-supersedes',
    'L04-start-during-stop-waits-for-teardown',
    'L05-stop-when-idle-is-applied',
    'L06-permission-denied-fails-the-start',
    'L07-stale-runtime-report-is-dropped',
    'L08-close-is-terminal',
    'L09-unexpected-teardown-is-a-failure',
    'L10-double-stop-coalesces',
    'L11-restart-crosses-teardown-before-start',
    'L12-retry-after-permission-granted',
    'L13-stale-revision-is-rejected',
    'L14-core-rejection-fails-without-running',
  ];

  test('the vector file is present and carries the contract ids', () async {
    expect(vectorsFile.existsSync(), isTrue,
        reason: 'run tests from packages/jjbox_bridge');
    final Map<String, Object?> payload =
        (jsonDecode(await vectorsFile.readAsString()) as Map<Object?, Object?>)
            .cast<String, Object?>();
    final List<Object?> vectors = payload['vectors'] as List<Object?>;
    final List<String> ids = <String>[
      for (final Object? vector in vectors)
        (vector! as Map<Object?, Object?>)['id'] as String,
    ];
    expect(ids, expectedIds);
  });

  test('every acceptance vector holds', () async {
    final Map<String, Object?> payload =
        (jsonDecode(await vectorsFile.readAsString()) as Map<Object?, Object?>)
            .cast<String, Object?>();
    final List<Object?> vectors = payload['vectors'] as List<Object?>;

    for (final Object? rawVector in vectors) {
      final Map<String, Object?> vector =
          (rawVector! as Map<Object?, Object?>).cast<String, Object?>();
      final String id = vector['id'] as String;
      final HostServiceStateMachine machine = HostServiceStateMachine(
        permission: _permission(vector['permission'] as String?),
      );
      for (final Object? rawStep in vector['steps']! as List<Object?>) {
        final Map<String, Object?> step =
            (rawStep! as Map<Object?, Object?>).cast<String, Object?>();
        final int revision = (step['revision'] as num?)?.toInt() ?? 0;
        switch (step['op'] as String) {
          case 'start':
            machine.start(
              revision,
              needsPermission: step['needsPermission'] as bool? ?? true,
            );
          case 'stop':
            machine.stop(revision);
          case 'restart':
            machine.restart(
              revision,
              needsPermission: step['needsPermission'] as bool? ?? true,
            );
          case 'close':
            machine.close(revision);
          case 'runtime':
            machine.runtimeReport(
              step['value'] == 'running'
                  ? RuntimeEvidence.running
                  : RuntimeEvidence.stopped,
              revision: revision,
            );
          case 'permission':
            machine.permissionReport(
              step['value'] == 'granted'
                  ? PermissionEvidence.granted
                  : PermissionEvidence.denied,
            );
          case 'fail':
            machine.failPending(step['message'] as String? ?? 'failure');
          default:
            fail('$id: unknown step ${step['op']}');
        }
      }

      final Map<String, Object?> expected =
          (vector['expected']! as Map<Object?, Object?>)
              .cast<String, Object?>();
      final Map<String, Object?> actual = machine.snapshot();
      expect(actual['state'], expected['state'], reason: '$id: state');
      if (expected['results'] != null) {
        expect(actual['results'], expected['results'], reason: '$id: results');
      }
      for (final Object? event
          in (expected['events'] as List<Object?>?) ?? const <Object?>[]) {
        expect(actual['events'], contains(event), reason: '$id: event $event');
      }
      if (expected['errors'] != null) {
        expect(actual['errors'], expected['errors'], reason: '$id: errors');
      }
    }
  });

  test('a newer intent always wins and close is terminal', () {
    final HostServiceStateMachine machine = HostServiceStateMachine(
      permission: PermissionEvidence.granted,
    );
    machine.start(1);
    machine.runtimeReport(RuntimeEvidence.running);
    expect(machine.state, ServiceState.running);
    machine.close(2);
    expect(machine.state, ServiceState.stopping);
    machine.runtimeReport(RuntimeEvidence.stopped);
    expect(machine.state, ServiceState.closed);
    machine.start(3);
    expect(machine.errors, contains('closed'));
    expect(machine.state, ServiceState.closed);
  });
}

PermissionEvidence _permission(String? value) {
  switch (value) {
    case 'granted':
      return PermissionEvidence.granted;
    case 'denied':
      return PermissionEvidence.denied;
    default:
      return PermissionEvidence.unrequested;
  }
}
