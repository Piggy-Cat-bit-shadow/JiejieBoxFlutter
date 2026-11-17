import 'package:intl/intl.dart' show NumberFormat;

// Trimmed from FlClash v0.9.3 lib/common/num.dart: only the display helpers the
// ported UI uses. The traffic formatter needs the core's TrafficShow model and
// returns with the data layer in A2.

final _compactFormat = NumberFormat.compact(locale: 'en');

extension NumExt on num {
  String get compact => _compactFormat.format(this);

  String fixed({int decimals = 2}) {
    var formatted = toStringAsFixed(decimals);
    if (formatted.contains('.')) {
      formatted = formatted.replaceAll(RegExp(r'0*$'), '');
      if (formatted.endsWith('.')) {
        formatted = formatted.substring(0, formatted.length - 1);
      }
    }
    return formatted;
  }
}
