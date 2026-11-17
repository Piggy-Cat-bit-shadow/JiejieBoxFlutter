/// Provider refresh without holding the profile write lock.
///
/// The core fetches and swaps provider data itself; this coordinator only guards
/// the ordering the contract requires: snapshot revisions, release everything,
/// refresh, then re-read and report whether a local edit raced the refresh. It
/// never rewrites a profile and never blocks a user edit.
library;

import 'host_bridge.dart';
import 'profile_transaction.dart';

class RefreshOutcome {
  const RefreshOutcome({
    required this.supported,
    this.refreshed = const <String>[],
    this.failed = const <String, String>{},
    this.durationMillis = 0,
    this.racedEdits = false,
  });

  final bool supported;
  final List<String> refreshed;
  final Map<String, String> failed;
  final int durationMillis;

  /// True when a profile revision changed while the refresh was in flight.
  final bool racedEdits;
}

class ProviderRefreshCoordinator {
  ProviderRefreshCoordinator({required this.bridge, required this.repository});

  final HostBridge bridge;
  final ProfileRepository repository;

  Future<RefreshOutcome> refresh(
    List<String> tags, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final Map<String, String> before = await _revisions();
    final ProviderRefreshResult result = await bridge.refreshProviders(
      tags,
      timeout: timeout,
    );
    final Map<String, String> after = await _revisions();
    return RefreshOutcome(
      supported: result.supported,
      refreshed: result.refreshed,
      failed: result.failed,
      durationMillis: result.durationMillis,
      racedEdits: _changed(before, after),
    );
  }

  Future<Map<String, String>> _revisions() async {
    final List<ProfileMeta> profiles = await repository.list();
    return <String, String>{
      for (final ProfileMeta meta in profiles) meta.id: meta.revision,
    };
  }

  static bool _changed(Map<String, String> before, Map<String, String> after) {
    if (before.length != after.length) {
      return true;
    }
    for (final MapEntry<String, String> entry in before.entries) {
      if (after[entry.key] != entry.value) {
        return true;
      }
    }
    return false;
  }
}
