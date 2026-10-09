import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

class SheetDetailHeader extends StatelessWidget {
  const SheetDetailHeader({
    required this.title,
    this.subtitle,
    this.favorite,
    this.trailing,
    super.key,
  }) : assert(
         favorite == null || trailing == null,
         'Pass favorite or trailing, not both.',
       );

  final String title;

  /// Secondary line under the title (e.g. a freshness timestamp), so metadata
  /// shares the header row instead of costing its own row of sheet height.
  final Widget? subtitle;

  /// Standard bookmark toggle target. When set, renders the favorite button.
  final Favorite? favorite;

  /// Custom trailing widget, used when the favorite is non-standard.
  final Widget? trailing;

  void _back(BuildContext context) {
    unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetDragHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space4,
            0,
            AppTheme.space12,
            AppTheme.space4,
          ),
          child: Row(
            children: [
              Pressable(
                onTap: () => _back(context),
                semanticLabel: AppI18n.of(context).commonBack,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: AppTextStyles.heading2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ?subtitle,
                  ],
                ),
              ),
              if (favorite != null) FavoriteToggleButton(favorite: favorite!),
              // Mutually exclusive with favorite (see assert): when a favorite
              // is set, trailing is null and this adds nothing.
              ?trailing,
            ],
          ),
        ),
      ],
    );
  }
}

/// Bookmark toggle for a [Favorite]: filled when saved, with an undo snackbar.
/// Reused by [SheetDetailHeader] and by full-page detail app bars. Requires a
/// [FavoritesBloc] above it in the tree.
class FavoriteToggleButton extends StatelessWidget {
  const FavoriteToggleButton({
    required this.favorite,
    super.key,
    this.onToggled,
    this.onPlate = false,
  });

  final Favorite favorite;

  final bool onPlate;

  final ValueChanged<bool>? onToggled;

  void _toggle(BuildContext context) {
    final wasSaved = context.read<FavoritesBloc>().state.contains(favorite.id);
    context.read<FavoritesBloc>().add(FavoriteToggled(favorite));
    onToggled?.call(!wasSaved);
    AppSnackbar.show(
      context,
      wasSaved
          ? AppI18n.of(context).favoriteRemoved
          : AppI18n.of(context).favoriteAdded,
      action: AppI18n.of(context).commonUndo,
      onAction: () => _toggle(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return BlocBuilder<FavoritesBloc, FavoritesState>(
      buildWhen: (p, n) => p.contains(favorite.id) != n.contains(favorite.id),
      builder: (context, state) {
        final saved = state.contains(favorite.id);
        return Pressable(
          onTap: () => _toggle(context),
          semanticLabel: saved
              ? AppI18n.of(context).favoriteRemove
              : AppI18n.of(context).commonFavorite,
          child: Padding(
            // 22pt icon + 11pt padding on each side = 44pt hit envelope.
            padding: onPlate ? EdgeInsets.zero : const EdgeInsets.all(11),
            child: Icon(
              saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              size: onPlate ? AppBarMetrics.icon : 22,
              color: cs.onSurface,
            ),
          ),
        );
      },
    );
  }
}
