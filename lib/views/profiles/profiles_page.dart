import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/constant.dart';
import '../../common/context.dart';
import '../../common/layout.dart';
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
        return GridView.builder(
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
            );
          },
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
  });

  final ProfileEntry profile;
  final int? groupValue;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final isSelected = profile.id == groupValue;
    final itemHeight = _profileItemHeight(context);
    return Card(
      enterActionsOnRight: true,
      radius: AppCorner.xl,
      isSelected: isSelected,
      onPressed: () => onChanged(profile.id),
      child: ListItem(
        key: Key(profile.id.toString()),
        minTileHeight: itemHeight,
        minVerticalPadding: listRowVerticalPadding,
        trailing: isSelected ? const SelectionBadge(size: 24) : null,
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
    );
  }
}
