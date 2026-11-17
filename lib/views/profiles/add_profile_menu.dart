import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../core/core_bridge.dart';
import '../../state/app_state.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../features/import/default_template.dart';
import '../../features/import/import_classifier.dart';
import '../../features/import/import_sheet.dart';

/// The four upstream ways to add a profile (FlClash v0.9.3
/// `lib/views/profiles/add.dart:130-162`), plus the two JiejieBox paths P2
/// adds: clipboard and the single built-in default config.
///
/// Entries that need a platform capability or the kernel parser are shown
/// disabled with the reason; they never pretend to work. Link, clipboard and
/// template open the real Form sheet; saving records a **draft** marked
/// unvalidated (kernel CheckConfig is not connected in this build).
class AddProfileMenu extends StatelessWidget {
  const AddProfileMenu({super.key, required this.builder});

  final Widget Function(VoidCallback open) builder;

  Future<String?> _readClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<void> _open(
    BuildContext context, {
    required ImportSource source,
    String initialText = '',
    String initialLabel = '',
  }) async {
    final state = AppStateScope.read(context);
    final draft = await showImportSheet(
      context,
      source: source,
      initialText: initialText,
      initialLabel: initialLabel,
    );
    if (draft == null) {
      return;
    }
    final sourceLabel = switch (source) {
      ImportSource.link => 'link',
      ImportSource.clipboard => 'clipboard',
      ImportSource.template => 'template',
    };
    if (state.connection.isAvailable && state.connection.hasRealHost) {
      final id = await state.importConfig(
        label: draft.label,
        content: draft.text,
        kind: switch (draft.format) {
          ImportFormat.clashYaml => 'clash-yaml',
          ImportFormat.sip008 => 'sip008',
          ImportFormat.shareLinks || ImportFormat.base64Links => 'link-list',
          _ => 'singbox-json',
        },
      );
      if (id != null) {
        state.noteAddIntent('${source.name}:${draft.format.name}');
      }
      return;
    }
    var validation = 'unvalidated';
    try {
      final result = await state.connection.checkConfig(draft.text);
      validation = result.ok ? 'validated' : 'invalid';
    } on BridgeException catch (error) {
      validation = 'unvalidated (check unavailable: ${error.code})';
    }
    if (!context.mounted) {
      return;
    }
    state.addProfileDraft(
      label: draft.label,
      subtitle: '$sourceLabel · ${draft.nodeCount} nodes · $validation',
      content: draft.text,
    );
    state.noteAddIntent('${source.name}:${draft.format.name}');
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
            subtitle: 'Platform camera / image picker (C)',
          ),
          PopupMenuItem(
            glyph: AppGlyphs.importFile,
            label: l10n.file,
            subtitle: 'Platform file picker (C)',
          ),
          PopupMenuItem(
            glyph: AppGlyphs.cloudDownload,
            label: l10n.link,
            onPressed: () => _open(context, source: ImportSource.link),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.copy,
            label: l10n.clipboardImport,
            onPressed: () async {
              final text = await _readClipboard();
              if (!context.mounted) return;
              await _open(
                context,
                source: ImportSource.clipboard,
                initialText: text ?? '',
              );
            },
          ),
          PopupMenuItem(
            section: const PopupMenuSection(),
            glyph: AppGlyphs.customize,
            label: l10n.defaultText,
            subtitle: 'Single built-in config',
            onPressed: () => _open(
              context,
              source: ImportSource.template,
              initialText: defaultConfigTemplate,
              initialLabel: defaultTemplateLabel(
                AppStateScope.read(context).profiles.length,
              ),
            ),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.puzzle,
            label: l10n.customProfile,
            subtitle: 'Bridge not connected (K14)',
          ),
        ],
      ),
    );
  }
}
