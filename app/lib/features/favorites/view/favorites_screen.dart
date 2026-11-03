import 'dart:async';
import 'dart:math' as math;

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

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _searchController = TextEditingController();

  double _toolbarHeight(BuildContext context, {required bool hasSubtitle}) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight =
        scaler.scale(AppTextStyles.bodyLarge.fontSize!) *
        (hasSubtitle ? 1.2 : AppTextStyles.bodyLarge.height!);
    final subtitleHeight = hasSubtitle
        ? scaler.scale(AppTextStyles.bodySmall.fontSize!) * 1.2
        : 0.0;
    return math
        .max(
          AppBarMetrics.barHeight,
          titleHeight + subtitleHeight + AppTheme.space8,
        )
        .ceilToDouble();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlocBuilder<FavoritesBloc, FavoritesState>(
        builder: (context, state) {
          final items = state.items;
          final pinnedCount = state.pinned.length;
          final query = _searchController.text.trim().toLowerCase();
          final visibleItems = query.isEmpty
              ? items
              : items
                    .where(
                      (item) =>
                          item.title.toLowerCase().contains(query) ||
                          item.subtitle.toLowerCase().contains(query),
                    )
                    .toList();
          return Column(
            children: [
              DetailAppBar(
                title: AppI18n.of(context).favoritesTitle,
                toolbarHeight: _toolbarHeight(
                  context,
                  hasSubtitle: items.isNotEmpty,
                ),
                subtitle: items.isEmpty
                    ? null
                    : AppI18n.of(
                        context,
                      ).favoritesSummary(items.length, pinnedCount),
              ),
              if (items.isNotEmpty || _searchController.text.isNotEmpty)
                _FavoritesSearchField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  onClear: () => setState(_searchController.clear),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : AppMotion.short,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.easeOut,
                  child: visibleItems.isEmpty
                      ? _FavoritesEmpty(filtered: items.isNotEmpty)
                      : KeyedSubtree(
                          key: const ValueKey('favorites-list'),
                          child: _FavoritesList(
                            items: visibleItems,
                            canReorder: query.isEmpty,
                          ),
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

class _FavoritesSearchField extends StatelessWidget {
  const _FavoritesSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space4,
        AppTheme.space16,
        AppTheme.space12,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: AppTextStyles.bodyRegular,
        decoration: InputDecoration(
          hintText: i18n.favoritesSearchHint,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: i18n.commonClear,
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusButton),
          ),
        ),
      ),
    );
  }
}

class _FavoritesList extends StatelessWidget {
  const _FavoritesList({required this.items, required this.canReorder});

  final List<Favorite> items;
  final bool canReorder;

  @override
  Widget build(BuildContext context) {
    // Reordering a filtered subset would overwrite the order of hidden items.
    if (!canReorder) {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: AppTheme.space32),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: items.length,
        itemBuilder: (context, index) =>
            _FavoriteListRow(key: ValueKey(items[index].id), fav: items[index]),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppTheme.space32),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: items.length,
      onReorderStart: (_) => unawaited(HapticService.instance.lightTap()),
      onReorderItem: (oldIndex, newIndex) {
        final next = [...items];
        next.insert(newIndex, next.removeAt(oldIndex));
        context.read<FavoritesBloc>().add(FavoritesReordered(next));
      },
      proxyDecorator: (child, index, animation) =>
          Material(color: Colors.transparent, child: child),
      itemBuilder: (context, index) {
        final fav = items[index];
        return _FavoriteListRow(key: ValueKey(fav.id), fav: fav, index: index);
      },
    );
  }
}

class _FavoriteListRow extends StatelessWidget {
  const _FavoriteListRow({required this.fav, this.index, super.key});

  final Favorite fav;
  final int? index;

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
                  if (index case final reorderIndex?)
                    ReorderableDragStartListener(
                      index: reorderIndex,
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
  const _FavoritesEmpty({this.filtered = false});

  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
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
                filtered ? Icons.search_off_rounded : Symbols.bookmark_rounded,
                size: 44,
                color: AppTheme.inkTertiary(cs.brightness),
              ),
              const SizedBox(height: AppTheme.space16),
              Text(
                filtered
                    ? AppI18n.of(context).favoritesNoMatches
                    : AppI18n.of(context).favoritesEmpty,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: AppTheme.space6),
              Text(
                filtered
                    ? AppI18n.of(context).favoritesNoMatchesHint
                    : AppI18n.of(context).favoritesEmptyHint,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
