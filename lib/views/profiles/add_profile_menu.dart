import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../ui/icons/app_glyphs.dart';

/// The four ways to add a profile, as FlClash v0.9.3 renders them in
/// `lib/views/profiles/add.dart:130-162`. The menu is the same; the actions are
/// wired by A2 (imports need the parser export, CONTRACTS K14), so choosing one
/// only records the intent - it never reports a fake success.
enum AddProfileIntent { qrCode, file, link, custom }

class AddProfileMenu extends StatelessWidget {
  const AddProfileMenu({super.key, required this.builder});

  final Widget Function(VoidCallback open) builder;

  void _choose(BuildContext context, AddProfileIntent intent) {
    AppStateScope.read(context).noteAddIntent(intent.name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return PopupAnchor(
      targetBuilder: builder,
      popupBuilder: (_) => PopupMenu(
        items: [
          PopupMenuItem(
            glyph: AppGlyphs.qrCode,
            label: l10n.qrcode,
            onPressed: () => _choose(context, AddProfileIntent.qrCode),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.importFile,
            label: l10n.file,
            onPressed: () => _choose(context, AddProfileIntent.file),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.cloudDownload,
            label: l10n.link,
            onPressed: () => _choose(context, AddProfileIntent.link),
          ),
          PopupMenuItem(
            section: const PopupMenuSection(),
            glyph: AppGlyphs.customize,
            label: l10n.customProfile,
            onPressed: () => _choose(context, AddProfileIntent.custom),
          ),
        ],
      ),
    );
  }
}
