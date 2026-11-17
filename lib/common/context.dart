import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';

extension AppContextExtension on BuildContext {
  AppLocalizations get appLocalizations => AppLocalizations.of(this);
}
