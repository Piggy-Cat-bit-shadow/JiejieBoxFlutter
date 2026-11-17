import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/scaffold/scaffold.dart';

/// Vendored from FlClash v0.9.3 `lib/features/form/form_page.dart`, with one
/// substitution: upstream renders `ErrorBanner` from `custom_issue.dart`, which
/// is bound to the Mihomo CustomIssue model. This client has no such model, so
/// the same slot is an error-token row (`_FormError`); see
/// OUTPUT/A/P2/NEW_COMPONENT_JUSTIFICATION.md.
class FormPage extends StatelessWidget {
  final String title;
  final VoidCallback onSave;
  final String? saveLabel;
  final List<IconButtonData> actions;
  final String? error;
  final bool saving;
  final List<Widget> children;

  const FormPage({
    super.key,
    required this.title,
    required this.onSave,
    this.saveLabel,
    this.actions = const [],
    this.error,
    this.saving = false,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: title,
      iconActions: actions,
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: saveLabel ?? context.appLocalizations.save,
        isLoading: saving,
        onPressed: saving ? null : onSave,
      ),
      body: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          if (error != null) _FormError(message: error!),
          ...children,
        ],
      ),
    );
  }
}

class _FormError extends StatelessWidget {
  const _FormError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colorScheme.errorContainer,
          shape: AppShape.all(AppCorner.md),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            message,
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colorScheme.onErrorContainer),
          ),
        ),
      ),
    );
  }
}
