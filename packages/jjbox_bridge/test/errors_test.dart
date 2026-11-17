import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

void main() {
  test('the vocabulary has the 19 contract codes with unique wire names', () {
    expect(HostErrorCode.values.length, 20);
    final Set<String> names = HostErrorCode.values
        .map((HostErrorCode code) => code.wireName)
        .toSet();
    expect(names.length, HostErrorCode.values.length);
    expect(names, contains('core_rejected_config'));
    expect(names, contains('config_findings'));
    expect(names, contains('core_start_failed'));
    expect(names, contains('unsupported'));
    expect(names, contains('provider_refresh_unsupported'));
    expect(names, contains('storage_corrupt'));
  });

  test('an unknown wire code degrades to internal but keeps the original', () {
    final HostError error = HostError.fromJson(<String, Object?>{
      'code': 'from_the_future',
      'message': 'newer host',
      'retryable': true,
    });
    expect(error.code, HostErrorCode.internal);
    expect(error.wireCode, 'from_the_future');
    expect(error.wireName, 'from_the_future');
    expect(error.toJson()['code'], 'from_the_future');
  });

  test('a known code round-trips without a wireCode marker', () {
    final HostError error = HostError.fromJson(<String, Object?>{
      'code': 'revision_mismatch',
      'message': 'stale',
      'retryable': true,
      'details': <String, Object?>{'expected': 'a'},
    });
    expect(error.code, HostErrorCode.revisionMismatch);
    expect(error.wireCode, isNull);
    expect(error.retryable, isTrue);
    expect(error.details['expected'], 'a');
  });

  test('A-side classes come from the contract mapping', () {
    expect(
      HostErrorCode.coreRejectedConfig.appClass,
      AppErrorClass.invalidConfig,
    );
    expect(HostErrorCode.configFindings.appClass, AppErrorClass.invalidConfig);
    expect(
      HostErrorCode.revisionMismatch.appClass,
      AppErrorClass.invalidConfig,
    );
    expect(HostErrorCode.unsupported.appClass, AppErrorClass.unsupported);
    expect(
      HostErrorCode.providerRefreshUnsupported.appClass,
      AppErrorClass.unsupported,
    );
    expect(HostErrorCode.timeout.appClass, AppErrorClass.timeout);
    expect(HostErrorCode.transportDisconnected.appClass, AppErrorClass.io);
    expect(HostErrorCode.coreUnavailable.appClass, AppErrorClass.io);
    expect(HostErrorCode.internal.appClass, AppErrorClass.internal);
    expect(HostErrorCode.closed.appClass, AppErrorClass.internal);
  });

  test('retryability matches the contract flags', () {
    expect(HostErrorCode.timeout.retryable, isTrue);
    expect(HostErrorCode.cancelled.retryable, isTrue);
    expect(HostErrorCode.closed.retryable, isFalse);
    expect(HostErrorCode.coreRejectedConfig.retryable, isFalse);
    expect(HostErrorCode.providerRefreshUnsupported.retryable, isFalse);
  });
}
