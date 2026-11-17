import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../form/form_page.dart';
import '../form/form_row.dart';
import 'default_template.dart';
import 'import_classifier.dart';

enum ImportSource { link, clipboard, template }

class ImportDraft {
  const ImportDraft({
    required this.label,
    required this.text,
    required this.format,
    required this.nodeCount,
    required this.append,
  });

  final String label;
  final String text;
  final ImportFormat format;
  final int nodeCount;
  final bool append;
}

Future<ImportDraft?> showImportSheet(
  BuildContext context, {
  required ImportSource source,
  String initialText = '',
  String initialLabel = '',
}) {
  return showFormSheet<ImportDraft>(
    context: context,
    builder: (_) => _ImportForm(
      source: source,
      initialText: initialText,
      initialLabel: initialLabel,
    ),
  );
}

class _ImportForm extends StatefulWidget {
  const _ImportForm({
    required this.source,
    required this.initialText,
    this.initialLabel = '',
  });

  final ImportSource source;
  final String initialText;
  final String initialLabel;

  @override
  State<_ImportForm> createState() => _ImportFormState();
}

class _ImportFormState extends State<_ImportForm> {
  late final TextEditingController _labelController;
  late final TextEditingController _textController;
  var _append = false;
  var _attempted = false;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.initialLabel);
    _textController = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _labelController.dispose();
    _textController.dispose();
    super.dispose();
  }

  String get _title => switch (widget.source) {
    ImportSource.link => context.appLocalizations.importFromLink,
    ImportSource.clipboard => context.appLocalizations.clipboardImport,
    ImportSource.template => context.appLocalizations.defaultText,
  };

  ImportPreview get _preview => classifyImport(_textController.text);

  String _fallbackLabel(ImportPreview preview) {
    if (preview.format == ImportFormat.singBoxJson) {
      return 'sing-box config';
    }
    if (preview.format == ImportFormat.clashYaml) {
      return 'Clash config';
    }
    if (preview.format == ImportFormat.sip008) {
      return 'SIP008';
    }
    if (preview.format == ImportFormat.subscriptionUrl) {
      return 'Subscription';
    }
    if (widget.source == ImportSource.template) {
      return defaultTemplateLabel(0);
    }
    return preview.nodeCount > 0
        ? 'Imported · ${preview.nodeCount} nodes'
        : 'Imported';
  }

  String? _error(ImportPreview preview) {
    if (!_attempted || preview.isUsable) {
      return null;
    }
    if (preview.format == ImportFormat.subscriptionUrl) {
      return 'Remote subscription needs the network/parser bridge (not connected)';
    }
    return preview.hints.isEmpty
        ? 'Nothing importable found'
        : preview.hints.first;
  }

  void _submit() {
    final preview = _preview;
    if (!preview.isUsable) {
      setState(() => _attempted = true);
      return;
    }
    final label = _labelController.text.trim();
    Navigator.of(context).pop(
      ImportDraft(
        label: label.isEmpty ? _fallbackLabel(preview) : label,
        text: preview.text,
        format: preview.format,
        nodeCount: preview.nodeCount,
        append: _append && !preview.isCompleteConfig,
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      setState(() => _attempted = true);
      return;
    }
    _textController.text = text;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final preview = _preview;
    final error = _error(preview);
    return FormPage(
      title: _title,
      saveLabel: l10n.submit,
      onSave: _submit,
      error: error,
      children: [
        if (widget.source == ImportSource.link)
          generateSection(
            items: [
              FormRow(
                title: l10n.name,
                trailing: FormRowTextField(
                  controller: _labelController,
                  hintText: l10n.optional,
                ),
              ),
              FormRow(
                title: l10n.link,
                trailing: FormRowTextField(
                  controller: _textController,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  hintText: l10n.required,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          )
        else
          Card(
            child: Column(
              children: [
                if (widget.source == ImportSource.clipboard)
                  ListItem(
                    leading: const GlyphIcon(AppGlyphs.copy),
                    title: Text(l10n.paste),
                    onTap: _pasteFromClipboard,
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _textController,
                    maxLines: 8,
                    decoration: InputDecoration(
                      hintText: l10n.optional,
                      border: const AppInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _PreviewCard(preview: preview),
        const SizedBox(height: 16),
        Card(
          child: ListItem.toggle(
            title: Text('Append to current profile'),
            value: _append,
            onChanged: preview.isCompleteConfig
                ? null
                : (value) => setState(() => _append = value),
          ),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.preview});

  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final style = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colorScheme.onSurfaceVariant);
    return Card(
      child: Column(
        children: [
          ListItem(
            title: const Text('Format'),
            trailing: Text(preview.formatLabel, style: style),
          ),
          ListItem(
            title: const Text('Nodes'),
            trailing: Text('${preview.nodeCount}', style: style),
          ),
          if (preview.skipped > 0)
            ListItem(
              title: const Text('Skipped'),
              trailing: Text('${preview.skipped}', style: style),
            ),
          for (final hint in preview.hints.take(2))
            ListItem(
              title: Text(hint, style: style),
              subtitle: const Text('Not validated by the kernel yet'),
            ),
        ],
      ),
    );
  }
}

/// The form's section wrapper: a `Card` grouping rows, as FlClash's
/// `generateSection` does in `lib/common/function.dart`.
Widget generateSection({required List<Widget> items}) {
  return Card(child: Column(children: items));
}
