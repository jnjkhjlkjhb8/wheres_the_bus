part of '../view/go_screen.dart';

enum OriginStatus { resolving, resolved, unavailable }

class _ODFields extends StatelessWidget {
  const _ODFields({
    required this.origin,
    required this.onEditOrigin,
    required this.onSwap,
    required this.destination,
    this.originStatus = OriginStatus.resolved,
    this.floating = false,
    this.onEnableLocation,
  });

  final PlannedPlace? origin;
  final OriginStatus originStatus;
  final VoidCallback onEditOrigin;
  final VoidCallback onSwap;

  /// The destination row's content: a tappable summary on the map, the live
  /// search field on the entry surface.
  final Widget destination;

  final bool floating;

  /// Offered next to the origin hint when location is off, so the fix is one
  /// tap from the thing it broke.
  final VoidCallback? onEnableLocation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final card = cs.brightness == Brightness.light
        ? Colors.white
        : cs.surfaceContainerHigh;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: floating ? card : cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        boxShadow: floating ? AppShadows.floating : null,
        border: floating ? null : Border.all(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space14,
          AppTheme.space4,
          AppTheme.space12,
          AppTheme.space4,
        ),
        child: Row(
          children: [
            const _ODRail(),
            const SizedBox(width: AppTheme.space10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OriginRow(
                    place: origin,
                    status: originStatus,
                    onTap: onEditOrigin,
                    onEnableLocation: onEnableLocation,
                  ),
                  const DividerLine(),
                  SizedBox(height: _kODRowHeight, child: destination),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.space4),
            Pressable(
              onTap: onSwap,
              semanticLabel: AppI18n.of(context).goSwapEndpoints,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.swap_vert_rounded,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const double _kODRowHeight = 48;

/// The line between the two ends — the same "living line" the rest of the app
/// draws a route with, at field scale. Each glyph centres on its own row.
class _ODRail extends StatelessWidget {
  const _ODRail();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 14,
      height: _kODRowHeight * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 1.5, height: 24, color: cs.outlineVariant),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                top: _kODRowHeight / AppTheme.space2 - AppTheme.space6,
              ),
              child: Icon(
                Icons.radio_button_checked_rounded,
                size: 13,
                color: cs.outline,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                bottom: _kODRowHeight / AppTheme.space2 - AppTheme.space8,
              ),
              child: Icon(
                Icons.location_on_rounded,
                size: 16,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OriginRow extends StatelessWidget {
  const _OriginRow({
    required this.place,
    required this.status,
    required this.onTap,
    this.onEnableLocation,
  });

  final PlannedPlace? place;
  final OriginStatus status;
  final VoidCallback onTap;
  final VoidCallback? onEnableLocation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filled = place != null;
    final label = switch ((filled, status)) {
      (true, _) => place!.name,
      (false, OriginStatus.resolving) => AppI18n.of(context).goLocating,
      _ => AppI18n.of(context).goChooseOrigin,
    };
    final denied = !filled && status == OriginStatus.unavailable;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        height: _kODRowHeight,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: filled ? cs.onSurface : cs.onSurfaceVariant,
                      fontWeight: filled ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (denied && onEnableLocation != null)
                    _LocationOffHint(onTap: onEnableLocation!),
                ],
              ),
            ),
            if (filled && place!.isCurrentLocation)
              Icon(
                Icons.my_location_rounded,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _LocationOffHint extends StatelessWidget {
  const _LocationOffHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          AppI18n.of(context).goNoLocation,
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        Pressable(
          onTap: onTap,
          semanticLabel: AppI18n.of(context).goEnableLocation,
          child: Text(
            AppI18n.of(context).goEnableLocation,
            style: AppTextStyles.bodyVerySmall.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlannerHeader extends StatelessWidget {
  const _PlannerHeader({
    required this.origin,
    required this.dest,
    required this.onEditOrigin,
    required this.onEditDest,
    required this.onSwap,
  });

  final PlannedPlace? origin;
  final PlannedPlace? dest;
  final VoidCallback onEditOrigin;
  final VoidCallback onEditDest;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filled = dest != null;
    return _ODFields(
      origin: origin,
      onEditOrigin: onEditOrigin,
      onSwap: onSwap,
      floating: true,
      destination: Pressable(
        onTap: onEditDest,
        semanticLabel: filled
            ? dest!.name
            : AppI18n.of(context).goChooseDestination,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            filled ? dest!.name : AppI18n.of(context).goChooseDestination,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodyLarge.copyWith(
              color: filled ? cs.onSurface : cs.onSurfaceVariant,
              fontWeight: filled ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlannerSheet extends StatelessWidget {
  const _PlannerSheet({
    required this.controller,
    required this.initialOffset,
    required this.state,
    required this.hasDestination,
    required this.timeMode,
    required this.timeAt,
    required this.routeCount,
    required this.lastRoute,
    required this.straightLineMeters,
    required this.onSelect,
    required this.onRetry,
    required this.onCancel,
    required this.onAdjustOptions,
    required this.onAdjustTime,
    required this.onToggleSave,
    required this.onPage,
    super.key,
  });

  final SheetController controller;
  final SheetOffset initialOffset;
  final PlanState state;
  final bool hasDestination;
  final _TimeMode timeMode;
  final DateTime timeAt;
  final int routeCount;
  final PlanRoute? lastRoute;
  final double? straightLineMeters;
  final void Function(PlanRoute) onSelect;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback onAdjustOptions;
  final VoidCallback onAdjustTime;
  final void Function(PlanRoute) onToggleSave;

  /// Asks the planner for earlier or later departures, carrying the opaque
  /// cursor the last response returned for that direction.
  final void Function(String cursor) onPage;

  @override
  Widget build(BuildContext context) {
    return AppSheet(
      controller: controller,
      initialOffset: initialOffset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space20,
              AppTheme.space4,
              AppTheme.space20,
              AppTheme.space10,
            ),
            child: Row(
              children: [
                Expanded(child: _SheetTitle(state: state)),
                // The depart/arrive time chip only makes sense once a
                // destination has been queried; the saved-routes box has no
                // time context.
                if (hasDestination) ...[
                  _TimeChip(
                    mode: timeMode,
                    at: timeAt,
                    onTap: onAdjustTime,
                  ),
                  const SizedBox(width: AppTheme.space8),
                ],
                _OptionsButton(onTap: onAdjustOptions),
              ],
            ),
          ),
          const DividerLine(),
          Expanded(
            child: _PlannerBody(
              state: state,
              routeCount: routeCount,
              lastRoute: lastRoute,
              straightLineMeters: straightLineMeters,
              onSelect: onSelect,
              onRetry: onRetry,
              onCancel: onCancel,
              onToggleSave: onToggleSave,
              onPage: onPage,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.state});

  final PlanState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = state.result?.routes.length ?? 0;
    // The departure time now lives in the header time chip, so the subtitle
    // just reports the result count.
    final sub = state.status == PlanStatus.success && count > 0
        ? AppI18n.of(context).suggestionCount(count)
        : AppI18n.of(context).goPlanning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppI18n.of(context).goSuggestedRoutes,
          style: AppTextStyles.heading2.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 3),
        Text(
          sub,
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _PageAction extends StatelessWidget {
  const _PageAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: cs.onSurface),
            const SizedBox(width: AppTheme.space6),
            Text(
              label,
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlannerBody extends StatelessWidget {
  const _PlannerBody({
    required this.state,
    required this.routeCount,
    required this.lastRoute,
    required this.straightLineMeters,
    required this.onSelect,
    required this.onRetry,
    required this.onCancel,
    required this.onToggleSave,
    required this.onPage,
  });

  final PlanState state;

  /// How many routes were asked for, so the skeleton is the shape of the answer
  /// and the real cards land without a reflow.
  final int routeCount;

  /// A saved route between the same two points, shown while waiting. Null when
  /// this trip is not one the rider has kept.
  final PlanRoute? lastRoute;

  /// Straight-line distance between the two ends, stated while waiting.
  final double? straightLineMeters;

  final void Function(PlanRoute) onSelect;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final void Function(PlanRoute) onToggleSave;
  final void Function(String cursor) onPage;

  @override
  Widget build(BuildContext context) {
    // The empty/saved-routes state now lives on the plan-entry page; this body
    // is only built once a destination exists, so it starts at the query state.
    switch (state.status) {
      case PlanStatus.initial:
      case PlanStatus.loading:
        return PlanWaitingPanel(
          routeCount: routeCount,
          lastRoute: lastRoute,
          straightLineMeters: straightLineMeters,
          onCancel: onCancel,
          onOpenLast: lastRoute == null ? null : () => onSelect(lastRoute!),
        );
      case PlanStatus.failure:
        final (title, hint) = switch (state.failure) {
          PlanFailureKind.timeout => (
            AppI18n.of(context).goPlannerSlowTitle,
            AppI18n.of(context).goPlannerSlowBody,
          ),
          PlanFailureKind.noRoute => (
            AppI18n.of(context).goNoRouteTitle,
            AppI18n.of(context).goNoRouteBody,
          ),
          PlanFailureKind.unavailable => (
            AppI18n.of(context).goUnavailableTitle,
            AppI18n.of(context).goUnavailableBody,
          ),
          _ => (
            AppI18n.of(context).goPlanFailedTitle,
            AppI18n.of(context).goPlanFailedBody,
          ),
        };
        return _GoMessage(
          icon: state.failure == PlanFailureKind.noRoute
              ? Icons.alt_route_rounded
              : Icons.cloud_off_rounded,
          title: title,
          hint: hint,
          actionLabel: AppI18n.of(context).commonRetryShort,
          onAction: onRetry,
        );
      case PlanStatus.success:
        final routes = state.result?.routes ?? const <PlanRoute>[];
        if (routes.isEmpty) {
          return _GoMessage(
            icon: Icons.alt_route_rounded,
            title: AppI18n.of(context).goNoRouteTitle,
            hint: AppI18n.of(context).goNoRouteHint,
          );
        }
        final earlier = state.result?.previousPageCursor ?? '';
        final later = state.result?.nextPageCursor ?? '';
        return ListView(
          padding: const EdgeInsets.all(AppTheme.space16),
          children: [
            if (earlier.isNotEmpty) ...[
              _PageAction(
                label: AppI18n.of(context).goEarlierDepartures,
                icon: Icons.keyboard_arrow_up_rounded,
                onTap: () => onPage(earlier),
              ),
              const SizedBox(height: AppTheme.space10),
            ],
            for (final (i, route) in routes.indexed) ...[
              if (i > 0) const SizedBox(height: AppTheme.space10),
              RouteOptionCard(
                route: route,
                highlighted: i == 0,
                isSaved: state.savedKeys.contains(route.savedKey),
                onTap: () => onSelect(route),
                onToggleSave: () => onToggleSave(route),
              ),
            ],
            if (later.isNotEmpty) ...[
              const SizedBox(height: AppTheme.space10),
              _PageAction(
                label: AppI18n.of(context).goLaterDepartures,
                icon: Icons.keyboard_arrow_down_rounded,
                onTap: () => onPage(later),
              ),
            ],
          ],
        );
    }
  }
}
