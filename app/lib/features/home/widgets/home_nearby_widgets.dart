part of '../home_screen.dart';

const _kShowReturnMapOffset = 72.0;

enum NearbyFilter {
  all,
  mrt,
  bus,
  youbike,
  tra,
  thsr;

  String labelOf(AppI18n i18n) {
    switch (this) {
      case NearbyFilter.all:
        return i18n.commonAll;
      case NearbyFilter.mrt:
        return i18n.modeMetro;
      case NearbyFilter.bus:
        return i18n.modeBus;
      case NearbyFilter.youbike:
        return i18n.modeBike;
      case NearbyFilter.tra:
        return i18n.modeTra;
      case NearbyFilter.thsr:
        return i18n.modeThsr;
    }
  }
}

class _FilterButtonGroup extends StatelessWidget {
  const _FilterButtonGroup({
    required this.selectedFilter,
    required this.onFilterChanged,
  });

  final NearbyFilter selectedFilter;
  final ValueChanged<NearbyFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const filters = NearbyFilter.values;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space20,
        vertical: AppTheme.space12,
      ),
      child: Row(
        spacing: AppTheme.space8,
        children: [
          for (final filter in filters)
            Pressable(
              onTap: () => onFilterChanged(filter),
              // 36 matches the second-layer station chips; the hit target is
              // widened back to the 44px floor rather than the painted chip.
              minTapSize: 44,
              child: AnimatedContainer(
                duration: AppMotion.micro,
                curve: AppMotion.easeInOut,
                height: 36,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space16,
                ),
                decoration: BoxDecoration(
                  color: filter == selectedFilter
                      ? cs.primary
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  filter.labelOf(AppI18n.of(context)),
                  style: AppTextStyles.bodySmall.copyWith(
                    fontWeight: filter == selectedFilter
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: filter == selectedFilter
                        ? cs.onPrimary
                        : cs.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NearbyStationsTab extends StatefulWidget {
  const _NearbyStationsTab({
    required this.onStationTap,
    required this.sheetController,
    required this.sheetTicks,
  });

  final ValueChanged<NearStationViewModel> onStationTap;
  final SheetController sheetController;

  /// Offset ticks that stop while a detail page covers this one — the filter
  /// row's reveal resizes the list, which must not happen mid-drag on the page
  /// above (see [CurrentPageSheetTicks]).
  final Listenable sheetTicks;

  @override
  State<_NearbyStationsTab> createState() => _NearbyStationsTabState();
}

class _NearbyStationsTabState extends State<_NearbyStationsTab> {
  NearbyFilter _selectedFilter = NearbyFilter.all;
  bool _showReturnMap = false;
  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    // No sheet expansion here: SheetScrollConfiguration already hands
    // list drags to the sheet, and force-animating to full on every drag
    // start re-pinned the sheet at 1.0 whenever the user tried to pull down.
    final show = n.metrics.pixels > _kShowReturnMapOffset;
    if (show != _showReturnMap) setState(() => _showReturnMap = show);
    return false;
  }

  // Collapse the sheet to reveal the map, and smoothly return the list to the
  // top at the same time (via the sheet's own PrimaryScrollController).
  void _returnToMap() {
    final scroll = PrimaryScrollController.maybeOf(context);
    if (scroll != null && scroll.hasClients) {
      unawaited(
        scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 400),
          curve: AppMotion.easeOut,
        ),
      );
    }
    unawaited(
      widget.sheetController.animateToDetent(
        AppSheetSnap.peek,
        reduced: AppMotion.reduced(context),
      ),
    );
  }

  // Filtered rows cached per (stations identity, filter) so sheet-driven
  // rebuilds don't re-filter an unchanged list.
  late List<NearStationViewModel> _filtered;
  List<NearStationViewModel>? _filteredSource;
  NearbyFilter? _filteredFilter;

  List<NearStationViewModel> _visibleStations(
    List<NearStationViewModel> stations,
  ) {
    if (!identical(stations, _filteredSource) ||
        _selectedFilter != _filteredFilter) {
      _filteredSource = stations;
      _filteredFilter = _selectedFilter;
      _filtered = stations.where(_matches).toList();
    }
    return _filtered;
  }

  bool _matches(NearStationViewModel s) {
    switch (_selectedFilter) {
      case NearbyFilter.all:
        return true;
      case NearbyFilter.mrt:
        return s.type == NearStationType.mrt;
      case NearbyFilter.bus:
        return s.type == NearStationType.bus;
      case NearbyFilter.youbike:
        return s.type == NearStationType.bike;
      case NearbyFilter.tra:
        return s.type == NearStationType.tra;
      case NearbyFilter.thsr:
        return s.type == NearStationType.thsr;
    }
  }

  Widget _buildFilterRow(BuildContext context) {
    final reduceMotion = AppMotion.reduced(context);
    return AnimatedBuilder(
      animation: widget.sheetTicks,
      builder: (context, child) {
        final metrics = widget.sheetController.metrics;
        final viewport =
            metrics?.viewportSize.height ?? MediaQuery.sizeOf(context).height;
        if (viewport <= 0) return const SizedBox.shrink();
        final peekPx = viewport * AppSheetSnap.peekFrac;
        final halfPx = viewport * AppSheetSnap.halfFrac;
        final offset = metrics?.offset ?? peekPx;
        final raw = ((offset - peekPx) / (halfPx - peekPx)).clamp(0.0, 1.0);
        final reveal = reduceMotion
            ? (raw >= 0.5 ? 1.0 : 0.0)
            : AppMotion.easeInOut.transform(raw);
        if (reveal == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: reveal,
            child: Opacity(opacity: reveal, child: child),
          ),
        );
      },
      child: _FilterButtonGroup(
        selectedFilter: _selectedFilter,
        onFilterChanged: (filter) {
          setState(() {
            _selectedFilter = filter;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildFilterRow(context),
        Expanded(
          child: BlocBuilder<NearbyBloc, NearbyState>(
            builder: (context, state) {
              final String kind;
              final Widget body;
              if (state.loading && state.stations.isEmpty) {
                kind = 'loading';
                body = LayoutBuilder(
                  builder: (context, constraints) {
                    // A row is 62 high at minimum; fill the viewport so the
                    // skeleton reads as a full list.
                    const rowExtent = 62.0;
                    final count = (constraints.maxHeight / rowExtent).ceil();
                    return Skeletonizer(
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: count,
                        itemBuilder: (context, i) => _NearbyStationRow(
                          station: _skeletonStations[i % 3],
                          onStationTap: (_) {},
                        ),
                      ),
                    );
                  },
                );
              } else if (state.error != null) {
                kind = 'error';
                body = ErrorStateView(
                  error: state.error!,
                  // Replays the exact failed query (dragged viewport or GPS,
                  // whichever it was) instead of falling back to device GPS.
                  onRetry: () =>
                      context.read<NearbyBloc>().add(const NearbyRetried()),
                );
              } else {
                final items = _visibleStations(state.stations);
                if (items.isEmpty) {
                  kind = 'empty';
                  body = _NearbyEmpty(
                    hasStationsNearby: state.stations.isNotEmpty,
                    filter: _selectedFilter,
                    onResetFilter: () =>
                        setState(() => _selectedFilter = NearbyFilter.all),
                  );
                } else {
                  kind = 'loaded';
                  body = Stack(
                    children: [
                      NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: items.length,
                          itemBuilder: (context, i) => _NearbyStationRow(
                            // Composite key: stationId alone is not guaranteed
                            // unique across transit types in this mixed list.
                            key: ValueKey(
                              '${items[i].type.name}:${items[i].stationId}',
                            ),
                            station: items[i],
                            onStationTap: widget.onStationTap,
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 40,
                        child: Center(
                          child: _ReturnMapPill(
                            visible: _showReturnMap,
                            onTap: _returnToMap,
                          ),
                        ),
                      ),
                    ],
                  );
                }
              }
              // 'loaded' stays keyed constant across refreshes so location
              // updates never re-fade the list.
              final reduceMotion = MediaQuery.disableAnimationsOf(context);
              return AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : AppMotion.short,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.easeOut,
                transitionBuilder: AppMotion.switchFade,
                child: KeyedSubtree(key: ValueKey(kind), child: body),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NearbyEmpty extends StatelessWidget {
  const _NearbyEmpty({
    required this.hasStationsNearby,
    required this.filter,
    required this.onResetFilter,
  });

  // Whether the unfiltered list has any stations at all — distinguishes
  // "nothing nearby" from "the active filter hid everything".
  final bool hasStationsNearby;
  final NearbyFilter filter;
  final VoidCallback onResetFilter;

  @override
  Widget build(BuildContext context) {
    final filterHidesResults = hasStationsNearby && filter != NearbyFilter.all;
    return _EmptyState(
      icon: filterHidesResults
          ? Icons.filter_alt_off_outlined
          : Icons.near_me_outlined,
      heading: filterHidesResults
          ? AppI18n.of(context).homeNoNearbyFiltered(
              filter.labelOf(AppI18n.of(context)),
            )
          : AppI18n.of(context).homeNoNearby,
      body: filterHidesResults
          ? AppI18n.of(context).homeNoNearbyFilteredBody
          : AppI18n.of(context).homeNoNearbyBody,
      actionLabel: filterHidesResults
          ? AppI18n.of(context).homeShowAllStops
          : null,
      onAction: filterHidesResults ? onResetFilter : null,
    );
  }
}

class _ReturnMapPill extends StatefulWidget {
  const _ReturnMapPill({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  State<_ReturnMapPill> createState() => _ReturnMapPillState();
}

class _ReturnMapPillState extends State<_ReturnMapPill>
    with SingleTickerProviderStateMixin {
  static const _dotSize = 12.0;
  static const _pillHeight = 44.0;
  static const _iconSize = 20.0;
  static const _iconGap = 6.0;
  static const _paddingH = 12.0;
  static final TextStyle _labelStyle = AppTextStyles.bodySmall.copyWith(
    fontWeight: FontWeight.w600,
  );

  late double _cachedPillWidth;

  double _computePillWidth(BuildContext context) {
    final tp = TextPainter(
      text: TextSpan(
        text: AppI18n.of(context).homeBackToMap,
        style: _labelStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final textWidth = tp.width;
    tp.dispose();
    return _paddingH * 2 + _iconSize + _iconGap + textWidth;
  }

  late final AnimationController _ctrl;
  late final Animation<double> _appear;
  late final Animation<double> _morph;
  late final Animation<double> _content;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AppMotion.sheet,
      reverseDuration: const Duration(milliseconds: 160),
      value: widget.visible ? 1 : 0,
    );
    _appear = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0, 0.4, curve: AppMotion.easeOut),
    );
    _morph = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.3, 1, curve: AppMotion.easeOut),
    );
    _content = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.65, 1, curve: AppMotion.easeOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedPillWidth = _computePillWidth(context);
  }

  @override
  void didUpdateWidget(covariant _ReturnMapPill old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      unawaited(widget.visible ? _ctrl.forward() : _ctrl.reverse());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final appear = reduce ? (widget.visible ? 1.0 : 0.0) : _appear.value;
        if (appear == 0) return const SizedBox.shrink();
        final morph = reduce ? 1.0 : _morph.value;
        final pillWidth = _cachedPillWidth;
        final width = _dotSize + (pillWidth - _dotSize) * morph;
        final height = _dotSize + (_pillHeight - _dotSize) * morph;
        return SizedBox(
          width: pillWidth,
          height: _pillHeight,
          child: Center(
            child: Opacity(
              opacity: appear,
              child: Transform.scale(
                scale: 0.85 + 0.15 * appear,
                child: Pressable(
                  onTap: widget.onTap,
                  semanticLabel: AppI18n.of(context).homeBackToMap,
                  child: Container(
                    width: width,
                    height: height,
                    clipBehavior: Clip.antiAlias,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(height / 2),
                      // Matches AppTheme.floatingControl: a drop shadow only
                      // reads against the light sheet, so dark mode skips the
                      // blur pass rather than painting it for nothing.
                      boxShadow: cs.brightness == Brightness.dark
                          ? const []
                          : AppShadows.floating,
                    ),
                    // Lay the label out at full pill width so the shrinking
                    // container clips it rather than reflowing it.
                    child: Opacity(
                      opacity: _content.value,
                      child: OverflowBox(
                        minWidth: pillWidth,
                        maxWidth: pillWidth,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.map_rounded,
                              size: _iconSize,
                              color: cs.onPrimary,
                            ),
                            const SizedBox(width: _iconGap),
                            Text(
                              AppI18n.of(context).homeBackToMap,
                              style: _labelStyle.copyWith(color: cs.onPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

final List<NearStationViewModel> _skeletonStations = [
  NearStationViewModel(
    type: NearStationType.mrt,
    stationId: '',
    stationName: BoneMock.chars(4, '囗'),
    lat: 0,
    lon: 0,
    walkingMinutes: 3,
    distanceMeters: 240,
  ),
  NearStationViewModel(
    type: NearStationType.bus,
    stationId: '',
    stationName: BoneMock.chars(6, '囗'),
    lat: 0,
    lon: 0,
    walkingMinutes: 5,
    distanceMeters: 420,
  ),
  NearStationViewModel(
    type: NearStationType.bike,
    stationId: '',
    stationName: BoneMock.chars(3, '囗'),
    lat: 0,
    lon: 0,
    walkingMinutes: 8,
    distanceMeters: 860,
  ),
];

class _NearbyStationRow extends StatelessWidget {
  const _NearbyStationRow({
    required this.station,
    required this.onStationTap,
    super.key,
  });

  final NearStationViewModel station;
  final ValueChanged<NearStationViewModel> onStationTap;

  void _onTap(BuildContext context) {
    onStationTap(station);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distance = station.routed
        ? formatNearDistance(station.distanceMeters)
        : AppI18n.of(
            context,
          ).aboutDistance(formatNearDistance(station.distanceMeters));
    final details = AppI18n.of(
      context,
    ).nearbyWalkAndDistance(station.walkingMinutes, distance);
    return Pressable(
      onTap: () => _onTap(context),
      semanticLabel: '${station.stationName} $details',
      child: Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: AppTheme.space12,
        ),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            TransportIcon(
              type: _nearbyIconType(station),
            ),
            const SizedBox(width: AppTheme.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    station.stationName,
                    style: AppTextStyles.bodyLarge.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppTheme.space2),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time_rounded,
                        size: 11,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          details,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.3,
                            fontFeatures: AppTextStyles.tabularFigures,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.space12),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
