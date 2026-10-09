import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_state.dart';
import 'package:wheres_the_bus/features/favorites/favorite_actions.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlocBuilder<FavoritesBloc, FavoritesState>(
        builder: (context, state) {
          final items = state.items;
          final pinnedCount = state.pinned.length;
          return Column(
            children: [
              DetailAppBar(
                title: AppI18n.of(context).favoritesTitle,
                subtitle: items.isEmpty
                    ? null
                    : AppI18n.of(
                        context,
                      ).favoritesSummary(items.length, pinnedCount),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : AppMotion.short,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.easeOut,
                  child: items.isEmpty
                      ? const _FavoritesEmpty()
                      : KeyedSubtree(
                          key: const ValueKey('favorites-list'),
                          child: _FavoritesList(items: items),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FavoritesList extends StatelessWidget {
  const _FavoritesList({required this.items});

  final List<Favorite> items;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppTheme.space32),
      itemCount: items.length,
      onReorderStart: (_) => unawaited(HapticService.instance.lightTap()),
      onReorderItem: (oldIndex, newIndex) {
        final next = [...items];
        next.insert(newIndex, next.removeAt(oldIndex));
        context.read<FavoritesBloc>().add(FavoritesReordered(next));
      },
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: child,
      ),
      itemBuilder: (context, index) {
        final fav = items[index];
        return _FavoriteListRow(
          key: ValueKey(fav.id),
          fav: fav,
          index: index,
        );
      },
    );
  }
}

class _FavoriteListRow extends StatelessWidget {
  const _FavoriteListRow({
    required this.fav,
    required this.index,
    super.key,
  });

  final Favorite fav;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('dismiss-${fav.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        unawaited(HapticService.instance.lightTap());
        final bloc = context.read<FavoritesBloc>()
          ..add(FavoriteRemoved(fav.id));
        AppSnackbar.show(
          context,
          AppI18n.of(context).favoritesRemoved,
          action: AppI18n.of(context).commonUndo,
          onAction: () => bloc.add(FavoriteToggled(fav)),
        );
      },
      background: Container(
        color: cs.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space24),
        child: Icon(
          Symbols.delete_rounded,
          color: cs.onErrorContainer,
          size: 22,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
        ),
        child: Pressable(
          onTap: () {
            openFavorite(context, fav);
          },
          semanticLabel: fav.title,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space16,
                AppTheme.space10,
                AppTheme.space4,
                AppTheme.space10,
              ),
              child: Row(
                children: [
                  TransportIcon(type: transportTypeForFavorite(fav)),
                  const SizedBox(width: AppTheme.space12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fav.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyLarge.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (fav.subtitle.isNotEmpty)
                          Text(
                            fav.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _PinButton(fav: fav),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.space8,
                      ),
                      child: Icon(
                        Symbols.drag_handle_rounded,
                        size: 22,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.fav});

  final Favorite fav;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: fav.pinned
          ? AppI18n.of(context).favoritesUnpin
          : AppI18n.of(context).favoritesPin,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Symbols.keep_rounded,
          fill: fav.pinned ? 1 : 0,
          size: 22,
          color: fav.pinned ? cs.onSurface : cs.onSurfaceVariant,
        ),
        onPressed: () {
          unawaited(HapticService.instance.lightTap());
          context.read<FavoritesBloc>().add(
            FavoritePinChanged(fav.id, pinned: !fav.pinned),
          );
        },
      ),
    );
  }
}

class _FavoritesEmpty extends StatelessWidget {
  const _FavoritesEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space32,
          0,
          AppTheme.space32,
          AppTheme.space48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.bookmark_rounded,
              size: 44,
              color: AppTheme.inkTertiary(cs.brightness),
            ),
            const SizedBox(height: AppTheme.space16),
            Text(
              AppI18n.of(context).favoritesEmpty,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: AppTheme.space6),
            Text(
              AppI18n.of(context).favoritesEmptyHint,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
