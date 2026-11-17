import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/constant.dart';
import '../../common/context.dart';
import '../../common/layout.dart';
import '../../features/form/form_page.dart';
import '../../features/form/form_row.dart';
import '../../state/app_state.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/null_status_illustration.dart';
import '../../ui/scaffold/scaffold.dart';
import 'add_profile_menu.dart';

const _infoGap = 4.0;

/// Same measured height as FlClash `_profileItemHeight`
/// (`lib/views/profiles/profiles.dart:22-28`): headline + 4 + footnote + 2x10.
double _profileItemHeight(BuildContext context) {
  final measure = MeasureScope.of(context);
  return measure.textHeight(AppTextStyle.headline) +
      _infoGap +
      measure.textHeight(AppTextStyle.footnote) +
      2 * listRowVerticalPadding;
}

/// Profiles, ported from FlClash v0.9.3 `ProfilesView` + `_ProfilesGrid` +
/// `ProfileItem`. Layout parameters are upstream's: 16 dp page padding,
/// 300.ap minimum card width, at most 3 columns, 8/12/16 spacing.
class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = AppStateScope.of(context);
    return Scaffold(
      title: l10n.profiles,
      actions: [
        AddProfileMenu(
          builder: (open) => IconButton(
            tooltip: l10n.addProfile,
            onPressed: open,
            icon: const GlyphIcon(AppGlyphs.addCircle),
          ),
        ),
      ],
      body: NullStatusSwitcher(
        isEmpty: state.profiles.isEmpty,
        nullStatus: NullStatus(
          label: l10n.nullTip(l10n.profiles),
          description: l10n.nullProfileDesc,
          illustration: NullStatusIllustration.profile,
          action: AddProfileMenu(
            builder: (open) => TonalButton(
              size: TonalButtonSize.bar,
              glyph: AppGlyphs.addCircle,
              label: l10n.addProfile,
              onPressed: open,
            ),
          ),
        ),
        child: const _ProfilesGrid(),
      ),
    );
  }
}

Future<void> _renameProfile(
  BuildContext context,
  AppState state,
  ProfileEntry profile,
) async {
  final name = await showFormSheet<String>(
    context: context,
    builder: (_) => _RenameForm(profile: profile),
  );
  if (name != null) {
    state.renameProfile(profile.id, name);
  }
}

Future<void> _deleteProfile(
  BuildContext context,
  AppState state,
  ProfileEntry profile,
) async {
  final confirmed = await showFormSheet<bool>(
    context: context,
    builder: (_) => _DeleteForm(profile: profile),
  );
  if (confirmed == true) {
    state.deleteProfile(profile.id);
  }
}

class _ProfilesGrid extends StatelessWidget {
  const _ProfilesGrid();

  static const _horizontalPadding = 16.0;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final spacing = cardSpacingOf(context, state.viewMode);
    final itemHeight = _profileItemHeight(context);
    return WidthBuilder(
      builder: (context, width) {
        final columns = getProfilesColumns(
          width - _horizontalPadding * 2,
          spacing: spacing,
          minItemWidth: profileItemMinWidth.ap(context),
        );
        final grid = GridView.builder(
          key: profilesStoreKey,
          padding: EdgeInsets.only(
            left: _horizontalPadding,
            right: _horizontalPadding,
            top: context.contentTopPadding,
            bottom: 16 + context.bottomInset,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: itemHeight,
          ),
          itemCount: state.profiles.length,
          itemBuilder: (context, index) {
            final profile = state.profiles[index];
            return ProfileItem(
              key: ValueKey(profile.id),
              profile: profile,
              groupValue: state.selectedProfileId,
              onChanged: state.selectProfile,
              onRename: () => _renameProfile(context, state, profile),
              onDelete: () => _deleteProfile(context, state, profile),
            );
          },
        );
        final error = state.lastActionError;
        if (error == null) {
          return grid;
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                child: ListItem(
                  leading: const GlyphIcon(AppGlyphs.info),
                  title: Text(error, maxLines: 3),
                ),
              ),
            ),
            Expanded(child: grid),
          ],
        );
      },
    );
  }
}

/// Ported from `ProfileItem` (`profiles.dart:268-536`), minus the subscription
/// expiry/update chips: those need the SubscriptionInfo API the kernel does not
/// expose (CONTRACTS K15), so showing them would be fabricated data.
class ProfileItem extends StatelessWidget {
  const ProfileItem({
    super.key,
    required this.profile,
    required this.groupValue,
    required this.onChanged,
    required this.onRename,
    required this.onDelete,
  });

  final ProfileEntry profile;
  final String? groupValue;
  final ValueChanged<String> onChanged;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isSelected = profile.id == groupValue;
    final itemHeight = _profileItemHeight(context);
    final l10n = context.appLocalizations;
    return ContextMenuRegion(
      menuItems: [
        PopupMenuItem(
          glyph: AppGlyphs.textShort,
          label: l10n.rename,
          onPressed: onRename,
        ),
        PopupMenuItem(
          danger: true,
          glyph: AppGlyphs.delete,
          label: l10n.delete,
          onPressed: onDelete,
        ),
      ],
      child: Card(
        enterActionsOnRight: true,
        radius: AppCorner.xl,
        isSelected: isSelected,
        onPressed: () => onChanged(profile.id),
        child: ListItem(
          key: Key(profile.id),
          minTileHeight: itemHeight,
          minVerticalPadding: listRowVerticalPadding,
          trailing: (!isSelected && profile.updatedAtMillis == 0)
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (profile.updatedAtMillis != 0)
                      Text(
                        _updatedLabel(profile.updatedAtMillis),
                        style: AppTextStyle.footnote.of(context).toLighter,
                      ),
                    if (isSelected) const SelectionBadge(size: 24),
                  ],
                ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.headline.of(context),
              ),
              const SizedBox(height: _infoGap),
              Text(
                profile.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote.of(context).toLighter,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameForm extends StatefulWidget {
  const _RenameForm({required this.profile});

  final ProfileEntry profile;

  @override
  State<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends State<_RenameForm> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.profile.label);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return FormPage(
      title: l10n.rename,
      onSave: () {
        final value = _controller.text.trim();
        if (value.isNotEmpty) {
          Navigator.of(context).pop(value);
        }
      },
      children: [
        Card(
          child: FormRow(
            title: l10n.name,
            trailing: FormRowTextField(
              controller: _controller,
              autofocus: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeleteForm extends StatelessWidget {
  const _DeleteForm({required this.profile});

  final ProfileEntry profile;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return FormPage(
      title: l10n.delete,
      saveLabel: l10n.delete,
      onSave: () => Navigator.of(context).pop(true),
      children: [Text('Delete "${profile.label}"? This cannot be undone.')],
    );
  }
}

String _updatedLabel(int millis) {
  final at = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
