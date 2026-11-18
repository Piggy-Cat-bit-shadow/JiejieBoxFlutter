/// The JiejieBox five-platform host bridge.
///
/// Transport-agnostic: [HostTransport] is the only seam. Import
/// `package:jjbox_bridge/testing.dart` for the in-memory host.
library;

export 'src/capabilities.dart';
export 'src/clipboard_gate.dart';
export 'src/envelope.dart';
export 'src/errors.dart';
export 'src/host_bridge.dart';
export 'src/host_channel.dart';
export 'src/host_socket.dart';
export 'src/import_pipeline.dart';
export 'src/profile_transaction.dart';
export 'src/runtime_events.dart';
export 'src/provider_refresh.dart';
export 'src/service_state.dart';
export 'src/sha256.dart';
