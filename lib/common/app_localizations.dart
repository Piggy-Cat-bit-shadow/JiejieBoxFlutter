import 'package:flutter/widgets.dart';
import 'package:prism_ui/l10n.dart';

import '../l10n/l10n.dart';

// Vendored from FlClash v0.9.3 lib/common/app_localizations.dart, minus the
// core/network error mappers (they belong to the data layer in A2).

final currentAppLocalizations = AppLocalizations.current;

class AppUiLocalizations implements UiLocalizations {
  const AppUiLocalizations(this._localizations);

  static const LocalizationsDelegate<UiLocalizations> delegate =
      _AppUiLocalizationsDelegate();

  final AppLocalizations _localizations;

  @override
  String get back => _localizations.back;

  @override
  String get cancel => _localizations.cancel;

  @override
  String get clearSearch => _localizations.clearSearch;

  @override
  String get close => _localizations.close;

  @override
  String get copy => _localizations.copy;

  @override
  String get cut => _localizations.cut;

  @override
  String get hidePassword => _localizations.hidePassword;

  @override
  String get dialog => _localizations.dialog;

  @override
  String get more => _localizations.more;

  @override
  String get noSearchResults => _localizations.noSearchResults;

  @override
  String get paste => _localizations.paste;

  @override
  String get reset => _localizations.reset;

  @override
  String get search => _localizations.search;

  @override
  String get select => _localizations.select;

  @override
  String get selectAll => _localizations.selectAll;

  @override
  String get showLess => _localizations.showLess;

  @override
  String get showMore => _localizations.showMore;

  @override
  String get showPassword => _localizations.showPassword;

  @override
  String get sort => _localizations.sort;

  @override
  String get submit => _localizations.submit;
}

class _AppUiLocalizationsDelegate
    extends LocalizationsDelegate<UiLocalizations> {
  const _AppUiLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.delegate.isSupported(locale);

  @override
  Future<UiLocalizations> load(Locale locale) =>
      AppLocalizations.load(locale).then(AppUiLocalizations.new);

  @override
  bool shouldReload(_AppUiLocalizationsDelegate old) => false;
}

Locale? getLocaleForString(String? localString) {
  if (localString == null) return null;
  final localSplit = localString.split('_');
  if (localSplit.length == 1) {
    return Locale(localSplit[0]);
  }
  if (localSplit.length == 2) {
    return Locale(localSplit[0], localSplit[1]);
  }
  if (localSplit.length == 3) {
    return Locale.fromSubtags(
      languageCode: localSplit[0],
      scriptCode: localSplit[1],
      countryCode: localSplit[2],
    );
  }
  return null;
}
