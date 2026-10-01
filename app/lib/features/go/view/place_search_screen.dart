import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_event.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/model/saved_place_icons.dart';
import 'package:wheres_the_bus/features/go/widgets/save_place_dialog.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';

Future<PlannedPlace> resolveCurrentPlace(AppI18n i18n) async {
  Position pos;
  try {
    pos = await LocationService.instance.currentPosition();
  } on Object {
    final cached = await LocationService.instance.lastKnownPosition();
    if (cached == null) rethrow;
    pos = cached;
  }
  return PlannedPlace(
    name: i18n.goCurrentLocation,
    latLng: LatLng(pos.latitude, pos.longitude),
    isCurrentLocation: true,
  );
}

/// Pushes the full-page place search and returns the picked place (or null on
/// back). Replaces the former modal bottom sheet; the planner's field-edit path
/// and the plan-entry fields both route here.
Future<PlannedPlace?> showPlaceSearchPage(
  BuildContext context, {
  required String fieldLabel,
  bool allowCurrentLocation = true,
}) {
  return Navigator.of(context).push<PlannedPlace>(
    MaterialPageRoute(
      builder: (_) => PlaceSearchScreen(
        fieldLabel: fieldLabel,
        allowCurrentLocation: allowCurrentLocation,
      ),
    ),
  );
}

/// The pushed search page: a plain [Scaffold] hosting [PlaceSearchView] with
/// its input active. Picking a place pops the page with it.
class PlaceSearchScreen extends StatelessWidget {
  const PlaceSearchScreen({
    required this.fieldLabel,
    this.allowCurrentLocation = true,
    super.key,
  });

  final String fieldLabel;
  final bool allowCurrentLocation;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: PlaceSearchView(
          showInput: true,
          autofocus: true,
          fieldLabel: fieldLabel,
          allowCurrentLocation: allowCurrentLocation,
          onBack: () => Navigator.of(context).maybePop(),
          onPicked: (place) => Navigator.of(context).pop(place),
        ),
      ),
    );
  }
}

typedef PlaceSearchHeaderBuilder =
    Widget Function(BuildContext context, Widget input);

class PlaceSearchView extends StatefulWidget {
  const PlaceSearchView({
    required this.onPicked,
    this.showInput = false,
    this.autofocus = false,
    this.fieldLabel,
    this.allowCurrentLocation = true,
    this.emptyHint,
    this.header,
    this.headerBuilder,
    this.onBack,
    super.key,
  });

  final ValueChanged<PlannedPlace> onPicked;

  /// Whether the built-in input row is shown. Ignored when [headerBuilder] is
  /// set — the host is then responsible for placing the field.
  final bool showInput;
  final bool autofocus;

  /// Null takes the standard placeholder, which needs a locale to resolve —
  /// and a const default has no context to resolve it with.
  final String? fieldLabel;
  final bool allowCurrentLocation;

  /// Shown when there are no saved places and no recents to fill the list — a
  /// quiet prompt rather than a blank surface.
  final String? emptyHint;

  final Widget? header;

  /// Replaces the built-in input row, handing back the wired text field for the
  /// host to place. When set, the field is focused on first frame.
  final PlaceSearchHeaderBuilder? headerBuilder;

  /// When set, a leading back button is shown in the built-in input row.
  final VoidCallback? onBack;

  @override
  State<PlaceSearchView> createState() => _PlaceSearchViewState();
}

class _PlaceSearchViewState extends State<PlaceSearchView> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  // Held directly rather than provided: the state is per-appearance, and the
  // rows below take callbacks, so nothing looks it up from the tree.
  final _bloc = PlaceSearchBloc()..add(const PlaceSearchStarted());

  LatLng? _bias;

  @override
  void initState() {
    super.initState();
    unawaited(_readBias());
    final hosted = widget.headerBuilder != null;
    if (hosted || (widget.showInput && widget.autofocus)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusNode.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_bloc.close());
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _readBias() async {
    final position = await LocationService.instance.lastKnownPosition();
    if (!mounted || position == null) return;
    setState(() => _bias = LatLng(position.latitude, position.longitude));
  }

  void _onQueryChanged(String value) =>
      _bloc.add(PlaceQueryChanged(value, bias: _bias));

  /// Acts on the bloc's one-shot outcomes: the pieces that need a
  /// [BuildContext] — snackbars, dialogs, and handing the place to the host.
  void _onEffect(BuildContext context, PlaceSearchState state) {
    final effect = state.effect;
    if (effect == null) return;
    final i18n = AppI18n.of(context);
    switch (effect.error) {
      case PlaceSearchErrorKind.location:
        AppSnackbar.show(
          context,
          i18n.goLocationUnavailable,
          type: SnackType.error,
        );
        return;
      case PlaceSearchErrorKind.place:
        AppSnackbar.show(
          context,
          i18n.goPlaceUnavailable,
          type: SnackType.error,
        );
        return;
      case null:
        break;
    }
    final place = effect.resolved;
    if (place == null) return;
    switch (effect.intent!) {
      case ResolveIntent.pick:
        widget.onPicked(place);
      case ResolveIntent.save:
        unawaited(_promptSave(place));
    }
  }

  Future<void> _useCurrentLocation() async {
    final i18n = AppI18n.of(context);
    _bloc.add(const LocationResolving(active: true));
    try {
      final place = await resolveCurrentPlace(i18n);
      // Disposing closes the bloc, so nothing may be posted to it after the
      // view is gone.
      if (!mounted) return;
      _bloc.add(const LocationResolving(active: false));
      widget.onPicked(place);
    } on Object catch (_) {
      if (!mounted) return;
      // The bloc turns the failure into an effect, so the snackbar is raised
      // from the one place that handles them.
      _bloc.add(const LocationResolving(active: false, failed: true));
    }
  }

  void _resolve(PlaceSuggestion suggestion, ResolveIntent intent) {
    _bloc.add(PlaceResolveRequested(suggestion.placeId, intent));
  }

  // A recent/saved place already carries coordinates, so it returns straight
  // away without a fresh Places details lookup.
  void _pickPlace(PlannedPlace place) {
    widget.onPicked(place);
  }

  // Right-swipe on a result or recent opens the save dialog prefilled with the
  // place's own name; on confirm it is pinned to saved places.
  Future<void> _promptSave(PlannedPlace place) async {
    final result = await showSavePlaceDialog(context, initialName: place.name);
    if (result == null || !mounted) return;
    _bloc.add(PlaceSaved(place, name: result.name, iconKey: result.iconKey));
    AppSnackbar.show(
      context,
      AppI18n.of(context).goPlaceSaved,
      type: SnackType.success,
    );
  }

  Future<void> _promptEdit(PlannedPlace place) async {
    final result = await showSavePlaceDialog(
      context,
      initialName: place.name,
      initialIcon: place.iconKey,
    );
    if (result == null || !mounted) return;
    _bloc.add(PlaceSaved(place, name: result.name, iconKey: result.iconKey));
  }

  void _removeRecent(PlannedPlace place) {
    unawaited(HapticService.instance.lightTap());
    _bloc.add(RecentRemoved(place));
    AppSnackbar.show(
      context,
      AppI18n.of(context).goRecentRemoved,
      action: AppI18n.of(context).commonUndo,
      onAction: () => _bloc.add(RecentRestored(place)),
    );
  }

  void _removeSaved(PlannedPlace place) {
    unawaited(HapticService.instance.lightTap());
    _bloc.add(SavedRemoved(place));
    AppSnackbar.show(
      context,
      AppI18n.of(context).goSavedPlaceRemoved,
      action: AppI18n.of(context).commonUndo,
      onAction: () => _bloc.add(SavedRestored(place)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PlaceSearchBloc, PlaceSearchState>(
      bloc: _bloc,
      // The effect is deliberately left in the state after it is consumed, so
      // only a change of effect may fire this — never an unrelated rebuild.
      listenWhen: (previous, current) => previous.effect != current.effect,
      listener: _onEffect,
      builder: (context, state) {
        final headerBuilder = widget.headerBuilder;
        return Column(
          children: [
            if (headerBuilder != null)
              headerBuilder(context, _buildInput(context, state))
            else if (widget.showInput)
              _buildInputRow(context, state),
            Expanded(child: _buildList(context, state)),
          ],
        );
      },
    );
  }

  /// The text field itself plus its clear button — everything the host needs to
  /// drop the search into a row of its own design.
  Widget _buildInput(BuildContext context, PlaceSearchState state) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            style: AppTextStyles.bodyLarge.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: widget.fieldLabel,
              hintStyle: AppTextStyles.bodyLarge.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            onChanged: _onQueryChanged,
          ),
        ),
        if (!state.isEmptyQuery)
          Pressable(
            onTap: () {
              _controller.clear();
              _onQueryChanged('');
            },
            semanticLabel: AppI18n.of(context).commonClear,
            minTapSize: 44,
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _buildInputRow(BuildContext context, PlaceSearchState state) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space12,
        AppTheme.space6,
        AppTheme.space16,
        AppTheme.space12,
      ),
      child: Row(
        children: [
          if (widget.onBack != null)
            Pressable(
              onTap: widget.onBack,
              semanticLabel: AppI18n.of(context).commonBack,
              child: SizedBox(
                width: 40,
                height: 44,
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 22,
                  color: cs.onSurface,
                ),
              ),
            ),
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.space14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.radiusCard),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppTheme.space8),
                  Expanded(child: _buildInput(context, state)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, PlaceSearchState state) {
    // Shortcuts and autocomplete are two readings of the same column, so they
    // cross-fade rather than hard-swapping. Keyed by which list is showing, not
    // by its contents: re-fading on every keystroke would strobe.
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : AppMotion.micro,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.easeOut,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.01),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: state.isEmptyQuery
          ? _buildShortcuts(context, state)
          : KeyedSubtree(
              key: const ValueKey('results'),
              child: _buildResults(context, state),
            ),
    );
  }

  Widget _buildResults(BuildContext context, PlaceSearchState state) {
    if (state.loading && state.results.isEmpty) return const _PlaceSkeleton();
    if (state.results.isEmpty) return const _PlaceEmpty();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppTheme.space24),
      itemCount: state.results.length,
      itemBuilder: (context, i) => _ResultRow(
        result: state.results[i],
        loading: state.pickingId == state.results[i].placeId,
        onTap: () => _resolve(state.results[i], ResolveIntent.pick),
        onSave: () => _resolve(state.results[i], ResolveIntent.save),
      ),
    );
  }

  Widget _buildShortcuts(BuildContext context, PlaceSearchState state) {
    return ListView(
      key: const ValueKey('shortcuts'),
      padding: const EdgeInsets.only(bottom: AppTheme.space24),
      children: [
        if (widget.header != null) widget.header!,
        if (widget.allowCurrentLocation)
          _CurrentLocationRow(
            loading: state.resolvingLocation,
            onTap: _useCurrentLocation,
          ),
        if (state.saved.isEmpty &&
            state.recents.isEmpty &&
            widget.emptyHint != null)
          _EmptyHint(widget.emptyHint!),
        if (state.saved.isNotEmpty) ...[
          _SectionLabel(AppI18n.of(context).goSavedPlaces),
          for (final place in state.saved)
            _SavedPlaceRow(
              key: ValueKey('saved-${_placeKey(place)}'),
              place: place,
              onTap: () => _pickPlace(place),
              onEdit: () => unawaited(_promptEdit(place)),
              onRemove: () => _removeSaved(place),
            ),
        ],
        if (state.recents.isNotEmpty) ...[
          _SectionLabel(AppI18n.of(context).searchRecent),
          for (final place in state.recents)
            _RecentPlaceRow(
              key: ValueKey('recent-${_placeKey(place)}'),
              place: place,
              onTap: () => _pickPlace(place),
              onSave: () => unawaited(_promptSave(place)),
              onRemove: () => _removeRecent(place),
            ),
        ],
      ],
    );
  }

  String _placeKey(PlannedPlace p) =>
      '${p.name}-${p.latLng.latitude}-${p.latLng.longitude}';
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space24,
        40,
        AppTheme.space24,
        AppTheme.space24,
      ),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyRegular.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Inset-grouped section header: a quiet label with air above it, in place of
/// the full-bleed grey slab this list used to separate sections with.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space20,
        AppTheme.space20,
        AppTheme.space6,
      ),
      child: Text(
        text,
        style: AppTextStyles.bodySmall.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CurrentLocationRow extends StatelessWidget {
  const _CurrentLocationRow({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: loading ? null : onTap,
      semanticLabel: AppI18n.of(context).goUseCurrentLocation,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: AppTheme.space14,
        ),
        child: Row(
          children: [
            Icon(Icons.my_location_rounded, size: 22, color: cs.primary),
            const SizedBox(width: AppTheme.space14),
            Text(
              AppI18n.of(context).goCurrentLocation,
              style: AppTextStyles.bodyLarge.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (loading)
              AppSpinner(size: 18, strokeWidth: 2, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _SwipeRow extends StatelessWidget {
  const _SwipeRow({
    required this.dismissKey,
    required this.child,
    this.onSaveSwipe,
    this.onDestructiveSwipe,
    this.destructiveIcon = Icons.delete_rounded,
  });

  final Key dismissKey;
  final Widget child;
  // Right-swipe (startToEnd). Shows the save affordance; returns without
  // dismissing the row.
  final VoidCallback? onSaveSwipe;
  // Left-swipe (endToStart). Removes the row.
  final VoidCallback? onDestructiveSwipe;
  final IconData destructiveIcon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final directions = <DismissDirection>{
      if (onSaveSwipe != null) DismissDirection.startToEnd,
      if (onDestructiveSwipe != null) DismissDirection.endToStart,
    };
    if (directions.isEmpty) return child;
    final direction = directions.length == 2
        ? DismissDirection.horizontal
        : directions.first;
    return Dismissible(
      key: dismissKey,
      direction: direction,
      background: onSaveSwipe == null
          ? null
          : Container(
              color: cs.surfaceContainerHigh,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.space24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bookmark_add_rounded,
                    color: cs.onSurface,
                    size: 22,
                  ),
                  const SizedBox(width: AppTheme.space8),
                  Text(
                    AppI18n.of(context).commonSave,
                    style: AppTextStyles.bodyRegular.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
      secondaryBackground: onDestructiveSwipe == null
          ? null
          : Container(
              color: cs.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.space24),
              child: Icon(
                destructiveIcon,
                color: cs.onErrorContainer,
                size: 22,
              ),
            ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          onSaveSwipe?.call();
          return false; // save/edit: snap back, don't remove the row
        }
        return true; // destructive: confirm here, remove in onDismissed
      },
      onDismissed: (dir) {
        if (dir == DismissDirection.endToStart) onDestructiveSwipe?.call();
      },
      child: child,
    );
  }
}

class _RecentPlaceRow extends StatelessWidget {
  const _RecentPlaceRow({
    required this.place,
    required this.onTap,
    required this.onSave,
    required this.onRemove,
    super.key,
  });

  final PlannedPlace place;
  final VoidCallback onTap;
  final VoidCallback onSave;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SwipeRow(
      dismissKey: ValueKey(
        'dismiss-recent-${place.name}-'
        '${place.latLng.latitude}-${place.latLng.longitude}',
      ),
      onSaveSwipe: onSave,
      onDestructiveSwipe: onRemove,
      child: _PlaceRow(
        leading: Icon(
          Icons.access_time_rounded,
          size: 22,
          color: cs.onSurfaceVariant,
        ),
        title: place.name,
        onTap: onTap,
      ),
    );
  }
}

class _SavedPlaceRow extends StatelessWidget {
  const _SavedPlaceRow({
    required this.place,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
    super.key,
  });

  final PlannedPlace place;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SwipeRow(
      dismissKey: ValueKey(
        'dismiss-saved-${place.name}-'
        '${place.latLng.latitude}-${place.latLng.longitude}',
      ),
      onSaveSwipe: onEdit,
      onDestructiveSwipe: onRemove,
      destructiveIcon: Icons.bookmark_remove_rounded,
      child: _PlaceRow(
        leading: Icon(
          SavedPlaceIcons.resolve(place.iconKey),
          size: 22,
          color: cs.onSurface,
        ),
        title: place.name,
        onTap: onTap,
        onLongPress: onEdit,
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.onTap,
    required this.onSave,
    this.loading = false,
  });

  final PlaceSuggestion result;
  final VoidCallback onTap;
  final VoidCallback onSave;

  /// True while this row's Places `details()` fetch (from a tap or a
  /// swipe-to-save) is in flight — shows a spinner in place of the leading
  /// icon instead of leaving the tap with no visible busy state.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SwipeRow(
      dismissKey: ValueKey('dismiss-result-${result.placeId}'),
      onSaveSwipe: loading ? null : onSave,
      child: _PlaceRow(
        leading: loading
            ? SizedBox(
                width: 22,
                height: 22,
                child: AppSpinner(
                  size: 18,
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant,
                ),
              )
            : Icon(
                Icons.place_outlined,
                size: 22,
                color: cs.onSurfaceVariant,
              ),
        title: result.primaryText,
        subtitle: result.secondaryText.isEmpty ? null : result.secondaryText,
        onTap: loading ? null : onTap,
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: title,
      child: Container(
        color: cs.surface,
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: AppTheme.space10,
        ),
        child: Row(
          children: [
            SizedBox(width: 22, child: Center(child: leading)),
            const SizedBox(width: AppTheme.space14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: cs.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceSkeleton extends StatelessWidget {
  const _PlaceSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: AppTheme.space24),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 5,
        itemBuilder: (context, i) => _ResultRow(
          result: PlaceSuggestion(
            placeId: 'skeleton-$i',
            primaryText: BoneMock.chars(i.isEven ? 6 : 4, '囗'),
            secondaryText: BoneMock.chars(10, '囗'),
          ),
          onTap: () {},
          onSave: () {},
        ),
      ),
    );
  }
}

class _PlaceEmpty extends StatelessWidget {
  const _PlaceEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space24,
        AppTheme.space48,
        AppTheme.space24,
        AppTheme.space48,
      ),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 40,
            color: AppTheme.inkTertiary(cs.brightness),
          ),
          const SizedBox(height: AppTheme.space12),
          Text(
            AppI18n.of(context).goNoPlaceMatch,
            style: AppTextStyles.bodyRegular.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
