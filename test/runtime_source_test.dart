import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/core/runtime_source.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

jb.HostCallback _status(int seq, String epoch, {String state = 'running'}) {
  return jb.HostCallback(
    type: jb.RuntimeEventTypes.status,
    seq: seq,
    data: <String, Object?>{
      'hostEpoch': epoch,
      'serviceState': state,
      'trafficAvailable': true,
      'uplinkTotalBytes': 10,
    },
  );
}

jb.HostCallback _groups(int seq, {String selected = 'node-a'}) {
  return jb.HostCallback(
    type: jb.RuntimeEventTypes.groups,
    seq: seq,
    data: <String, Object?>{
      'groups': <Object?>[
        <String, Object?>{
          'tag': 'proxy',
          'type': 'selector',
          'selectable': true,
          'selected': selected,
          'items': <Object?>[
            <String, Object?>{'tag': 'node-a', 'type': 'shadowsocks', 'urlTestDelay': 42},
            <String, Object?>{'tag': 'node-b', 'type': 'trojan'},
          ],
        },
      ],
    },
  );
}

jb.HostCallback _connections(int seq, String instance, List<Map<String, Object?>> events, {bool reset = false}) {
  return jb.HostCallback(
    type: jb.RuntimeEventTypes.connections,
    seq: seq,
    data: <String, Object?>{'reset': reset, 'instanceId': instance, 'events': events},
  );
}

jb.HostCallback _log(int seq, String message) {
  return jb.HostCallback(
    type: jb.RuntimeEventTypes.log,
    seq: seq,
    data: <String, Object?>{
      'entries': <Object?>[<String, Object?>{'level': 2, 'name': 'info', 'message': message}],
    },
  );
}

void main() {
  test('groups replace wholesale and expose the selected member', () {
    final RuntimeSource source = RuntimeSource();
    expect(source.apply(_groups(1)), isTrue);
    expect(source.groups, hasLength(1));
    expect(source.groups.first.selected, 'node-a');
    expect(source.groups.first.member('node-b')?.type, 'trojan');
  });

  test('duplicate and stale sequence numbers are dropped', () {
    final RuntimeSource source = RuntimeSource();
    expect(source.apply(_groups(1)), isTrue);
    expect(source.apply(_groups(2, selected: 'node-b')), isTrue);
    expect(source.groups.first.selected, 'node-b');
    // Same seq: a duplicate frame must not move visible state.
    expect(source.apply(_groups(2, selected: 'node-a')), isFalse);
    expect(source.groups.first.selected, 'node-b');
    // Older seq: also dropped.
    expect(source.apply(_groups(1, selected: 'node-a')), isFalse);
    expect(source.groups.first.selected, 'node-b');
  });

  test('a sequence gap is counted so the UI can mark data as possibly incomplete', () {
    final RuntimeSource source = RuntimeSource();
    source.apply(_groups(1));
    source.apply(_groups(5));
    expect(source.gapCount, 1);
  });

  test('a new host epoch resets every cached collection', () {
    final RuntimeSource source = RuntimeSource();
    source.apply(_status(1, 'epoch-a'));
    source.apply(_groups(2));
    source.apply(_log(3, 'hello'));
    expect(source.groups, isNotEmpty);
    expect(source.logs, isNotEmpty);

    final bool changed = source.apply(_status(4, 'epoch-b', state: 'idle'));
    expect(changed, isTrue);
    expect(source.hostEpoch, 'epoch-b');
    expect(source.groups, isEmpty, reason: 'frames from the old host must not survive');
    expect(source.logs, isEmpty);
    expect(source.status?.serviceState, 'idle');
  });

  test('logs are bounded and clear on the contract signal', () {
    final RuntimeSource source = RuntimeSource(maxLogs: 10);
    for (int index = 1; index <= 25; index++) {
      source.apply(_log(index, 'line $index'));
    }
    expect(source.logs, hasLength(10));
    expect(source.logs.first.message, 'line 16');

    source.apply(const jb.HostCallback(type: jb.RuntimeEventTypes.logsCleared, seq: 26));
    expect(source.logs, isEmpty);
  });

  test('connection events merge deltas, close removes, and a new instance resets', () {
    final RuntimeSource source = RuntimeSource(maxConnections: 3);
    source.apply(_connections(1, 'inst-1', <Map<String, Object?>>[
      <String, Object?>{'type': 'new', 'id': 'c1', 'network': 'tcp', 'destination': '1.2.3.4:443', 'outbound': 'proxy'},
    ]));
    expect(source.connections, hasLength(1));

    source.apply(_connections(2, 'inst-1', <Map<String, Object?>>[
      <String, Object?>{'type': 'update', 'id': 'c1', 'uplinkDelta': 5, 'downlinkDelta': 7},
    ]));
    expect(source.connections.single.uplinkTotalBytes, 5);
    expect(source.connections.single.destination, '1.2.3.4:443', reason: 'a delta must not blank immutable fields');

    source.apply(_connections(3, 'inst-1', <Map<String, Object?>>[
      <String, Object?>{'type': 'closed', 'id': 'c1', 'closedAt': 99},
    ]));
    expect(source.connections, isEmpty, reason: 'a closed connection must disappear');

    source.apply(_connections(4, 'inst-1', <Map<String, Object?>>[
      <String, Object?>{'type': 'new', 'id': 'c2'},
    ]));
    source.apply(_connections(5, 'inst-2', <Map<String, Object?>>[
      <String, Object?>{'type': 'new', 'id': 'c3'},
    ]));
    expect(source.connections.map((jb.RuntimeConnectionEvent e) => e.id), <String>['c3'],
        reason: 'a reload replaces the box, so the old instance rows must go');
  });

  test('unknown event types are ignored instead of throwing', () {
    final RuntimeSource source = RuntimeSource();
    expect(source.apply(const jb.HostCallback(type: 'runtime.something-new', seq: 1)), isFalse);
    expect(source.apply(const jb.HostCallback(type: '', seq: 2)), isFalse);
  });
}
