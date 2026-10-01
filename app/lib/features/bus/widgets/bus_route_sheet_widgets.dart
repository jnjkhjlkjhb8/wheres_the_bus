part of '../view/bus_route_screen.dart';

class _RouteSheet extends StatelessWidget {
  const _RouteSheet({
    required this.tabController,
    required this.sheetController,
    required this.scrollController,
    required this.timelineController,
    required this.flashStopUid,
    required this.direction,
    required this.isLoading,
    required this.onDirectionChanged,
    required this.sheetAnimation,
    required this.routeName,
    required this.dirNames,
    required this.routeState,
    required this.pickingStop,
    required this.pinnedNextStopIndex,
    required this.targetStopUid,
    required this.leadStopUid,
    required this.boundPlate,
    required this.onPickStop,
    required this.onSwipeVehicle,
    required this.onCancelPick,
    required this.onTapStop,
    required this.onTapVehicle,
  });

  final TabController tabController;
  final SheetController sheetController;
  final ScrollController scrollController;
  final ScrollController timelineController;
  final String? flashStopUid;
  final int direction;
  final bool isLoading;
  final ValueChanged<int> onDirectionChanged;
  final Animation<double> sheetAnimation;
  final String routeName;
  final List<String> dirNames;
  final BusRouteState routeState;

  /// Pick-mode: a bus is pinned and the rider is choosing an alight stop.
  final bool pickingStop;

  /// Index of the pinned bus's next stop; stops before it are dimmed as passed.
  final int? pinnedNextStopIndex;

  /// The chosen alight stop, or null before one is tapped.
  final String? targetStopUid;

  /// The 提前提醒站, derived from 提前站數. Null at lead 0 (the default).
  final String? leadStopUid;

  /// The plate the running 下車提醒 follows, so its marker row carries the
  /// seat glyph.
  final String? boundPlate;

  final void Function(String uid) onPickStop;

  /// Swiping a vehicle marker right opens the flow bound to that plate.
  final void Function(String plate, int markerIndex) onSwipeVehicle;

  /// Leaves pick-mode with nothing started.
  final VoidCallback onCancelPick;

  /// Outside pick-mode: aiming the map from the sheet. Tapping a stop centres
  /// on its marker; tapping a bus centres on it and selects it.
  final ValueChanged<String> onTapStop;
  final ValueChanged<String> onTapVehicle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Route identity strip (finding 5): the floating app bar this doubles for
    // is painted under the sheet, so it needs the current headsign too.
    final dirName = direction == 0 ? dirNames[0] : dirNames[1];
    final sole = routeState.route?.soleDirection;

    // Only the timeline observes live ETA churn; the sheet skeleton around it
    // stays put across frames.
    final timeline =
        BlocSelector<BusRouteBloc, BusRouteState, List<TimelineStop>>(
          selector: (s) => _stopsFor(AppI18n.of(context), s),
          builder: (context, stops) => _HorizontalRouteTimeline(
            stops: stops,
            direction: direction,
            controller: timelineController,
            flashStopUid: flashStopUid,
            picking: pickingStop,
            pinnedNextStopIndex: pinnedNextStopIndex,
            targetUid: targetStopUid,
            onPickStop: onPickStop,
            onStopTap: onTapStop,
            onVehicleTap: onTapVehicle,
          ),
        );

    final tabsContent = Column(
      children: [
        RouteTabBar(
          controller: tabController,
          tabs: [
            AppI18n.of(context).busStopList,
            AppI18n.of(context).busRouteDetails,
          ],
          raised: true,
        ),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [
              if (isLoading)
                _ShimmerStopList(scrollController: scrollController)
              else if (routeState.error != null)
                ErrorStateView(
                  error: routeState.error!,
                  onRetry: () =>
                      context.read<BusRouteBloc>().add(const BusRouteStarted()),
                )
              else
                // Scoped to etaMap so a live frame repaints the stop rows only,
                // not the tab bar or detail tab.
                BlocSelector<BusRouteBloc, BusRouteState, List<TimelineStop>>(
                  selector: (s) => _stopsFor(AppI18n.of(context), s),
                  builder: (context, stops) => _StopListTab(
                    stops: stops,
                    scrollController: scrollController,
                    flashStopUid: flashStopUid,
                    // While a 下車站 is being chosen the rows pick; outside the
                    // flow they are inert. One list, one meaning at a time.
                    picking: pickingStop,
                    firstPickableIndex: firstAlightIndex(pinnedNextStopIndex),
                    targetStopUid: targetStopUid,
                    leadStopUid: leadStopUid,
                    boundPlate: boundPlate,
                    onPickStop: onPickStop,
                    onSwipeVehicle: onSwipeVehicle,
                    onTapStop: onTapStop,
                    onTapVehicle: onTapVehicle,
                  ),
                ),
              _RouteDetailTab(state: routeState),
            ],
          ),
        ),
      ],
    );

    return AppSheet(
      controller: sheetController,
      initialOffset: AppSheetSnap.peek,
      snapGrid: pickingStop
          ? const SheetSnapGrid(
              snaps: [AppSheetSnap.full],
              minFlingSpeed: AppSheetSnap.flingSpeed,
            )
          : _kRouteSnapGrid,
      child: Column(
        children: [
          AnimatedBuilder(
            animation: sheetAnimation,
            builder: (context, _) {
              final progress = sheetAnimation.value;
              // Route identity fades in as the sheet approaches full — by the
              // time it's readable, the app bar behind the sheet is gone.
              final identityOpacity = ((progress - 0.6) / 0.4).clamp(
                0.0,
                1.0,
              );
              return Column(
                children: [
                  const SheetDragHandle(),
                  if (identityOpacity > 0)
                    Opacity(
                      opacity: identityOpacity,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTheme.space16,
                          AppTheme.space4,
                          AppTheme.space16,
                          0,
                        ),
                        child: Row(
                          children: [
                            Text(
                              routeName,
                              style: AppTextStyles.bodyRegular.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            if (dirName.isNotEmpty) ...[
                              const SizedBox(width: AppTheme.space6),
                              Expanded(
                                child: Text(
                                  dirName,
                                  style: AppTextStyles.bodySmall.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AppTheme.space12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.space16),
            child: pickingStop
                ? Center(child: AlightPickCapsule(onCancel: onCancelPick))
                : sole != null
                ? AppStaticSegment(
                    label: dirNames[sole].isNotEmpty
                        ? dirNames[sole]
                        : routeName,
                    leading: Icons.repeat_rounded,
                    semanticLabel: AppI18n.of(context).busOneWayRoute(
                      dirNames[sole].isNotEmpty ? dirNames[sole] : routeName,
                    ),
                  )
                : AppSlidingSegment<int>(
                    options: {
                      0: dirNames[0].isNotEmpty
                          ? dirNames[0]
                          : AppI18n.of(context).busDirectionOutbound,
                      1: dirNames[1].isNotEmpty
                          ? dirNames[1]
                          : AppI18n.of(context).busDirectionInbound,
                    },
                    value: direction,
                    onChanged: onDirectionChanged,
                  ),
          ),
          const SizedBox(height: AppTheme.space12),
          Expanded(
            child: AnimatedBuilder(
              animation: sheetAnimation,
              builder: (context, _) {
                final progress = sheetAnimation.value;
                final showTimeline = progress < 0.75;
                final showTabs = progress > 0.25;

                final timelineOpacity = (1.0 - progress * 1.6).clamp(
                  0.0,
                  1.0,
                );
                final tabsOpacity = ((progress - 0.25) * 1.6).clamp(0.0, 1.0);

                return Stack(
                  children: [
                    if (showTimeline)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: _tlCellHeight,
                        child: Opacity(
                          opacity: timelineOpacity,
                          child: IgnorePointer(
                            ignoring: progress > 0.5,
                            child: timeline,
                          ),
                        ),
                      ),

                    if (showTabs)
                      Positioned.fill(
                        child: Opacity(
                          opacity: tabsOpacity,
                          child: IgnorePointer(
                            ignoring: progress < 0.5,
                            child: tabsContent,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
