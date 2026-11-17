/// The host service state machine of the bridge contract.
///
/// The state is *derived* from (newest intent revision, runtime evidence) and
/// never assigned by a step. `running` is only reachable through runtime
/// evidence; an accepted `service.start` ack is not evidence.
library;

/// Observable service states, in the order they appear in the contract.
enum ServiceState {
  idle,
  awaitingPermission,
  starting,
  running,
  stopping,
  failed,
  closed,
}

/// Intents that move the machine. Each carries a monotonically increasing
/// revision; an older revision is rejected.
enum ServiceIntent { start, stop, restart, close }

/// What happened to one intent.
enum ServiceOutcome { applied, coalesced, superseded }

/// One recorded intent outcome, rendered as `start@1:applied`.
class IntentResult {
  const IntentResult(this.intent, this.revision, this.outcome);

  final ServiceIntent intent;
  final int revision;
  final ServiceOutcome outcome;

  @override
  String toString() => '${intent.name}@$revision:${outcome.name}';
}

/// Runtime evidence reported by the host: is anything actually up?
enum RuntimeEvidence { running, stopped }

/// Permission evidence for VPN/TUN style permissions.
enum PermissionEvidence { granted, denied, unrequested }

class _Pending {
  _Pending(this.intent, this.revision, this.needsPermission);

  final ServiceIntent intent;
  final int revision;
  bool needsPermission;
}

/// Latest-intent reconciler shared by Dart and every native host.
class HostServiceStateMachine {
  HostServiceStateMachine({
    PermissionEvidence permission = PermissionEvidence.unrequested,
  }) : _permission = permission;

  ServiceState _state = ServiceState.idle;
  int _revision = 0;
  _Pending? _pending;
  RuntimeEvidence _runtime = RuntimeEvidence.stopped;
  PermissionEvidence _permission;
  bool _closed = false;

  final List<IntentResult> _results = <IntentResult>[];
  final List<String> _events = <String>[];
  final List<String> _errors = <String>[];

  ServiceState get state => _state;

  int get revision => _revision;

  bool get isClosed => _closed;

  List<IntentResult> get results => List<IntentResult>.unmodifiable(_results);

  List<String> get events => List<String>.unmodifiable(_events);

  List<String> get errors => List<String>.unmodifiable(_errors);

  /// `start` intent. Returns `applied`, `pending` or `rejected:<reason>`.
  String start(int revision, {bool needsPermission = true}) {
    if (_closed) {
      _errors.add('closed');
      return 'rejected:closed';
    }
    if (revision <= _revision) {
      _errors.add('stale_revision');
      return 'rejected:stale_revision';
    }
    _revision = revision;
    final bool hadPending = _pending != null;
    if (_pending?.intent == ServiceIntent.start) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.coalesced,
        ),
      );
      _pending = null;
    } else if (_pending != null) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.superseded,
        ),
      );
      _pending = null;
    }
    if (_runtime == RuntimeEvidence.running && !hadPending) {
      _results.add(
        IntentResult(ServiceIntent.start, revision, ServiceOutcome.applied),
      );
      _permission = PermissionEvidence.granted;
      _emit('service.state');
      return 'applied';
    }
    _pending = _Pending(
      ServiceIntent.start,
      revision,
      needsPermission && _permission != PermissionEvidence.granted,
    );
    _state = _derive();
    _emit('service.state');
    return 'pending';
  }

  String stop(int revision) {
    if (_closed) {
      _errors.add('closed');
      return 'rejected:closed';
    }
    if (revision <= _revision) {
      _errors.add('stale_revision');
      return 'rejected:stale_revision';
    }
    _revision = revision;
    if (_pending?.intent == ServiceIntent.stop) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.coalesced,
        ),
      );
      _pending = null;
    } else if (_pending != null) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.superseded,
        ),
      );
      _pending = null;
    }
    _pending = _Pending(ServiceIntent.stop, revision, false);
    _state = _derive();
    _emit('service.state');
    return 'pending';
  }

  String restart(int revision, {bool needsPermission = true}) {
    if (_closed) {
      _errors.add('closed');
      return 'rejected:closed';
    }
    if (revision <= _revision) {
      _errors.add('stale_revision');
      return 'rejected:stale_revision';
    }
    _revision = revision;
    if (_pending != null) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.superseded,
        ),
      );
    }
    _pending = _Pending(
      ServiceIntent.restart,
      revision,
      needsPermission && _permission != PermissionEvidence.granted,
    );
    _state = _derive();
    _emit('service.state');
    return 'pending';
  }

  String close(int revision) {
    if (_closed) {
      _errors.add('closed');
      return 'rejected:closed';
    }
    if (revision <= _revision) {
      _errors.add('stale_revision');
      return 'rejected:stale_revision';
    }
    _revision = revision;
    if (_pending != null) {
      _results.add(
        IntentResult(
          _pending!.intent,
          _pending!.revision,
          ServiceOutcome.superseded,
        ),
      );
    }
    _pending = _Pending(ServiceIntent.close, revision, false);
    _state = _derive();
    _emit('service.state');
    return 'pending';
  }

  /// Runtime evidence from the host. A report stamped with an older revision
  /// describes a world that no longer exists and is dropped.
  String runtimeReport(RuntimeEvidence value, {int revision = 0}) {
    if (revision != 0 && revision < _revision) {
      _errors.add('stale_runtime_report');
      return 'dropped';
    }
    _runtime = value;
    final _Pending? pending = _pending;
    if (pending == null) {
      if (value == RuntimeEvidence.running) {
        _state = ServiceState.running;
        _emit('service.state');
        return 'observed';
      }
      if (value == RuntimeEvidence.stopped && _state == ServiceState.running) {
        _fail('service.lost');
        return 'observed';
      }
      _state = _derive();
      return 'observed';
    }
    switch (pending.intent) {
      case ServiceIntent.start:
      case ServiceIntent.restart:
        if (value == RuntimeEvidence.running) {
          _resolve(ServiceOutcome.applied);
          _state = ServiceState.running;
          _emit('service.state');
          return 'applied';
        }
        if (pending.intent == ServiceIntent.restart) {
          _state = ServiceState.starting;
          return 'waiting';
        }
        return 'waiting';
      case ServiceIntent.stop:
        if (value == RuntimeEvidence.stopped) {
          _resolve(ServiceOutcome.applied);
          _state = ServiceState.idle;
          _emit('service.state');
          return 'applied';
        }
        return 'waiting';
      case ServiceIntent.close:
        if (value == RuntimeEvidence.stopped) {
          _resolve(ServiceOutcome.applied);
          _state = ServiceState.closed;
          _closed = true;
          _emit('service.state');
          return 'applied';
        }
        return 'waiting';
    }
  }

  /// Permission evidence. Denial fails the pending start instead of leaving it
  /// waiting forever.
  String permissionReport(PermissionEvidence value) {
    if (value == PermissionEvidence.unrequested) {
      throw ArgumentError.value(value, 'value', 'must be granted or denied');
    }
    _permission = value;
    final _Pending? pending = _pending;
    if (pending != null &&
        (pending.intent == ServiceIntent.start ||
            pending.intent == ServiceIntent.restart)) {
      if (value == PermissionEvidence.denied) {
        _fail('permission_denied');
        _emit('permission.changed');
        return 'failed';
      }
      pending.needsPermission = false;
      _state = _derive();
      _emit('permission.changed');
      return 'proceed';
    }
    _emit('permission.changed');
    return 'ignored';
  }

  /// The host reports that the pending intent failed (core rejected the config,
  /// transport died, ...).
  String failPending(String message) {
    if (_pending == null) {
      return 'ignored';
    }
    _fail(message);
    _emit('service.state');
    return 'failed';
  }

  Map<String, Object?> snapshot() => <String, Object?>{
    'state': _state.name,
    'revision': _revision,
    'results': _results.map((IntentResult r) => r.toString()).toList(),
    'events': List<String>.from(_events),
    'errors': List<String>.from(_errors),
  };

  ServiceState _derive() {
    if (_closed) {
      return ServiceState.closed;
    }
    final _Pending? pending = _pending;
    if (pending != null) {
      switch (pending.intent) {
        case ServiceIntent.start:
          return pending.needsPermission
              ? ServiceState.awaitingPermission
              : ServiceState.starting;
        case ServiceIntent.stop:
          return ServiceState.stopping;
        case ServiceIntent.restart:
          return ServiceState.starting;
        case ServiceIntent.close:
          return ServiceState.stopping;
      }
    }
    if (_runtime == RuntimeEvidence.running) {
      return ServiceState.running;
    }
    if (_state == ServiceState.failed) {
      return ServiceState.failed;
    }
    return ServiceState.idle;
  }

  void _resolve(ServiceOutcome outcome) {
    final _Pending? pending = _pending;
    if (pending == null) {
      return;
    }
    _results.add(IntentResult(pending.intent, pending.revision, outcome));
    _pending = null;
  }

  void _fail(String message) {
    _state = ServiceState.failed;
    final _Pending? pending = _pending;
    if (pending != null) {
      _results.add(
        IntentResult(pending.intent, pending.revision, ServiceOutcome.applied),
      );
    }
    _pending = null;
    _errors.add(message);
    _emit('service.failed');
  }

  void _emit(String event) {
    if (_events.isEmpty || _events.last != event) {
      _events.add(event);
    }
  }
}
