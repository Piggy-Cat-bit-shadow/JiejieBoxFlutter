import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import 'common/app_localizations.dart';
import 'common/constant.dart';
import 'l10n/l10n.dart';
import 'shell/app_scopes.dart';
import 'shell/home_shell.dart';
import 'state/app_state.dart';

/// The Prism app root, following FlClash `lib/application.dart:159-199`:
/// PrismApp owns theme/locale/text scale; the manager stack (here: scopes and
/// shell) is installed through `builder` so it sits under the app's Theme.
class JiejieBoxApp extends StatelessWidget {
  const JiejieBoxApp({super.key, required this.state, this.locale});

  final AppState state;

  /// Forces a locale for deterministic Widget/Golden tests; null follows the
  /// host, as FlClash does.
  final Locale? locale;

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: seededColorScheme(
      seedColor: defaultSeedColor,
      brightness: brightness,
      style: ColorStyle.soft,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return PrismApp(
          title: appName,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          locale: locale,
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: state.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          textScale: state.textScale,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          builder: (context, child) {
            return AppStateScope(
              state: state,
              child: AppScopes(state: state, child: child!),
            );
          },
          home: const HomeShell(),
        );
      },
    );
  }
}
