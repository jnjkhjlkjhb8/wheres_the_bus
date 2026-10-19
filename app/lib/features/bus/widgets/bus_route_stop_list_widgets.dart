part of '../view/bus_route_screen.dart';

bool _slServiceEnded(TimelineStop stop) => stop.serviceEnded;

/// Single collapsed notice replacing 40 identical per-row "末班已過" labels
/// when every stop in the direction has ended for the day (PRODUCT.md:
/// "glanceable over informative").
Widget _slServiceEndedBanner(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: AppTheme.space20,
      vertical: AppTheme.space12,
    ),
    color: cs.surfaceContainerHighest,
    child: Text(
      AppI18n.of(context).busServiceEndedToday,
      style: AppTextStyles.bodyRegular.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
    ),
  );
}

Future<void> _slAwaitRouteReload(BuildContext context) async {
  final bloc = context.read<BusRouteBloc>()..add(const BusRouteStarted());
  await bloc.stream
      .firstWhere((state) => !state.loading)
      .timeout(const Duration(seconds: 8), onTimeout: () => bloc.state);
}

// Public only so tests can mount the list from stop fixtures instead of the
// whole route screen.
class StopListTab extends StatelessWidget {
  const StopListTab({
    required this.stops,
    required this.scrollController,
    required this.flashStopUid,
    this.picking = false,
    this.firstPickableIndex = 0,
    this.targetStopUid,
    this.leadStopUid,
    this.boundPlate,
    this.onPickStop,
    this.onSwipeVehicle,
    this.onTapStop,
    this.onTapVehicle,
    super.key,
  });

  final List<TimelineStop> stops;
  final ScrollController scrollController;
  final String? flashStopUid;

  /// Whether a 下車站 is being chosen. The same rule as the timeline above —
  /// only stops the pinned bus has not reached yet — so the two views can
  /// never offer different answers.
  final bool picking;
  final int firstPickableIndex;
  final String? targetStopUid;

  /// The 提前提醒站 — derived from 提前站數, not chosen. Null at lead 0, which
  /// is the default, so most sessions never show it.
  final String? leadStopUid;

  /// The plate the running 下車提醒 follows, so its marker row can carry the
  /// seat glyph.
  final String? boundPlate;

  final ValueChanged<String>? onPickStop;

  final void Function(String plate, int markerIndex)? onSwipeVehicle;

  /// Outside pick-mode a row tap centres the map on that stop's marker, and a
  /// marker tap centres it on the bus — the sheet and the map are two views of
  /// the same thing, so pointing at one should aim the other.
  final ValueChanged<String>? onTapStop;
  final ValueChanged<String>? onTapVehicle;

  @override
  Widget build(BuildContext context) {
    // All-ended collapses the per-row 末班已過 repetition into one banner;
    // a partial end still needs the per-row label — it's real signal there.
    final allStopsEnded = stops.isNotEmpty && stops.every(_slServiceEnded);

    // Vehicle positions are derived once for the whole direction rather than
    // per row: the signal is a comparison between neighbours, which a row
    // cannot see on its own.
    final markers = busVehicleMarkerIndices(stops);

    final children = _stopRows(context, markers, allStopsEnded)
      // Last row of the list rather than a fixed footer: it dates the ETAs
      // above it, and pinning it would cost a strip of height on a sheet whose
      // whole job is showing as many stops as it can.
      ..add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kTimelineGutter,
            AppTheme.space12,
            AppTheme.space16,
            AppTheme.space16,
          ),
          child: BlocSelector<BusRouteBloc, BusRouteState, DateTime?>(
            selector: (state) => state.updatedAt,
            builder: (context, updatedAt) => FreshnessStamp(at: updatedAt),
          ),
        ),
      );

    return RefreshIndicator(
      onRefresh: () => _slAwaitRouteReload(context),
      child: Column(
        children: [
          if (allStopsEnded) _slServiceEndedBanner(context),
          Expanded(
            child: ListView(
              controller: scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _stopRows(
    BuildContext context,
    Set<int> markers,
    bool allEnded,
  ) => [
    for (var index = 0; index < stops.length; index++) ...[
      if (markers.contains(index)) _vehicleRow(context, index, stops[index]),
      if (_isFareBoundary(index))
        _FareSectionDivider(stopName: stops[index].name),
      _stopRow(index, allEnded),
    ],
  ];

  bool _isFareBoundary(int index) =>
      index > 0 &&
      stops[index].fareSection == 2 &&
      stops[index - 1].fareSection == 1 &&
      !stops[index].isBuffer;

  Widget _vehicleRow(BuildContext context, int index, TimelineStop stop) {
    final plate = stop.plate;
    final tappableMarker = _tappableVehicle(context, plate);
    return plate.isEmpty || onSwipeVehicle == null || picking
        ? tappableMarker
        : AlightSwipeRow(
            rowKey: plate,
            onSwiped: () => onSwipeVehicle!(plate, index),
            child: tappableMarker,
          );
  }

  Widget _tappableVehicle(BuildContext context, String plate) {
    final marker = _vehicleMarker(context, plate);
    return !_canSelectVehicle(plate) || onTapVehicle == null
        ? marker
        : Pressable(
            onTap: () => onTapVehicle!(plate),
            semanticLabel: AppI18n.of(context).busVehicleHere,
            child: marker,
          );
  }

  bool _canSelectVehicle(String plate) => plate.isNotEmpty && !picking;

  Widget _vehicleMarker(BuildContext context, String plate) {
    return TimelineVehicleMarker(
      semanticLabel: _vehicleSemantics(AppI18n.of(context), plate),
      // The marker stands for the bus this stop is counting down to, so
      // its plate is the one to print. Empty when the feed sent none.
      label: plate.isEmpty ? null : plate,
      badge: _vehicleBadge(plate),
    );
  }

  bool _boundVehicle(String plate) => plate.isNotEmpty && plate == boundPlate;
  String _vehicleSemantics(AppI18n i18n, String plate) =>
      _boundVehicle(plate) ? i18n.alightBoundVehicle : i18n.busVehicleHere;
  IconData? _vehicleBadge(String plate) =>
      _boundVehicle(plate) ? Icons.airline_seat_recline_extra_rounded : null;

  bool _liveConnection(int index, int neighbor) {
    if (neighbor < 0 || neighbor >= stops.length) return false;
    return stops[index].isLiveEta && stops[neighbor].isLiveEta;
  }

  VoidCallback? _stopAction(int index, TimelineStop stop) {
    if (picking) return _pickAction(index, stop);
    return onTapStop == null ? null : () => onTapStop!(stop.uid);
  }

  VoidCallback? _pickAction(int index, TimelineStop stop) =>
      index >= firstPickableIndex ? () => onPickStop?.call(stop.uid) : null;

  Widget _stopRow(int i, bool allStopsEnded) {
    final stop = stops[i];
    return _StopListItem(
      stop: stop,
      isFirst: i == 0,
      isLast: i == stops.length - 1,
      // The spine reads as "a bus is actually on its way to these stops":
      // solid where the ETA is a live countdown, hollow where it is only a
      // scheduled departure that has not happened yet.
      liveAbove: _liveConnection(i, i - 1),
      liveBelow: _liveConnection(i, i + 1),
      isFlashed: stop.uid == flashStopUid,
      // Both marks outlive picking: mid-ride the list is what answers
      // "which stop do I get off at, and where will it buzz".
      isAlightTarget: targetStopUid == stop.uid,
      isLeadStop: leadStopUid == stop.uid,
      dimmedForPick: picking && i < firstPickableIndex,
      onPick: _stopAction(i, stop),
      suppressEtaLabel: allStopsEnded,
    );
  }
}

/// The 兩段票 boundary: fares change from here on.
class _FareSectionDivider extends StatelessWidget {
  const _FareSectionDivider({required this.stopName});

  final String stopName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kTimelineGutter,
        AppTheme.space6,
        AppTheme.space16,
        AppTheme.space6,
      ),
      child: Row(
        children: [
          Text(
            AppI18n.of(context).busSecondSectionFrom(stopName),
            style: AppTextStyles.bodyVerySmall.copyWith(
              fontSize: 11,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppTheme.space10),
          Expanded(child: Container(height: 1, color: cs.outlineVariant)),
        ],
      ),
    );
  }
}

class _StopListItem extends StatelessWidget {
  const _StopListItem({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.liveAbove,
    required this.liveBelow,
    required this.isFlashed,
    this.onPick,
    this.suppressEtaLabel = false,
    this.isAlightTarget = false,
    this.isLeadStop = false,
    this.dimmedForPick = false,
  });

  final bool isAlightTarget;

  final bool isLeadStop;

  /// A stop the pinned bus has already passed while picking — visible, but not
  /// a candidate.
  final bool dimmedForPick;

  final TimelineStop stop;
  final bool isFirst;
  final bool isLast;

  /// Whether the spine segment above / below this stop is on a live run.
  final bool liveAbove;
  final bool liveBelow;

  /// True for the few seconds after this stop's map marker was tapped.
  final bool isFlashed;

  /// Chooses this stop as the 下車站. Null outside pick-mode, which is what
  /// makes the row inert: the list has one meaning at a time, and outside the
  /// flow it is a list of stops and their arrival times, nothing more.
  final VoidCallback? onPick;

  /// True when every stop in the direction has ended, so the list-level
  /// banner already states it once and the per-row ETA text is redundant.
  final bool suppressEtaLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // A marker-tap flash reuses the live/approaching row treatment (bold +
    // tint) so a tapped stop reads the same as the active one.
    final isHighlighted = _highlighted;
    final highlightFill = _highlightFill(cs);

    final nameWidget = _stopName(context, cs, isHighlighted);

    final row = Pressable(
      // Picking a 下車站 is a once-per-trip act, so the whole row carries it
      // rather than a per-row button — forty identical chips down the list
      // would be louder than the arrival times they sat beside.
      enabled: onPick != null,
      onTap: onPick ?? () {},
      semanticLabel: _semanticLabel(AppI18n.of(context)),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        color: isHighlighted ? highlightFill : null,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TimelineSpine(
                kind: _nodeKind,
                lineAbove: !isFirst,
                lineBelow: !isLast,
                travelledAbove: liveAbove,
                travelledBelow: liveBelow,
                dimmed: suppressEtaLabel,
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(
                    0,
                    AppTheme.space10,
                    AppTheme.space16,
                    AppTheme.space10,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: nameWidget),
                      const SizedBox(width: AppTheme.space12),
                      if (!suppressEtaLabel) _buildEta(AppI18n.of(context), cs),
                      if (isLeadStop) ...[
                        const SizedBox(width: AppTheme.space10),
                        Icon(
                          Icons.notifications_rounded,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                      ],
                      if (isAlightTarget) ...[
                        const SizedBox(width: AppTheme.space10),
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: cs.onSurface,
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusChip,
                            ),
                          ),
                          child: Icon(
                            Icons.download_rounded,
                            size: 14,
                            color: cs.surface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // A stop the bus has already passed stays readable but takes no taps:
    // dimming without removing is what tells the rider the list continues.
    if (dimmedForPick) {
      return IgnorePointer(child: Opacity(opacity: 0.35, child: row));
    }
    return row;
  }

  bool get _highlighted => stop.active || isFlashed || isAlightTarget;
  Color _highlightFill(ColorScheme colors) =>
      colors.brightness == Brightness.light
      ? colors.onSurface.withValues(alpha: 0.06)
      : colors.surfaceContainerHigh;
  TimelineNodeKind get _nodeKind => isFirst || isLast
      ? TimelineNodeKind.terminus
      : TimelineNodeKind.intermediate;

  Widget _stopName(BuildContext context, ColorScheme cs, bool isHighlighted) {
    final nameWidget = Text(
      stop.name,
      style: AppTextStyles.bodyRegular.copyWith(
        fontWeight: isHighlighted ? FontWeight.w700 : FontWeight.w400,
        color: cs.onSurface,
      ),
      overflow: TextOverflow.ellipsis,
    );

    return switch (stop.secondaryLabel) {
      null => nameWidget,
      'TERMINUS' => _terminusName(context, nameWidget),
      _ => _secondaryName(cs, nameWidget),
    };
  }

  Widget _secondaryName(ColorScheme cs, Widget name) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      name,
      const SizedBox(height: AppTheme.space2),
      Text(
        stop.secondaryLabel!,
        style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
      ),
    ],
  );

  Widget _terminusName(BuildContext context, Widget name) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: name),
      const SizedBox(width: AppTheme.space6),
      TimelineStopTag(AppI18n.of(context).busTerminus, solid: false),
    ],
  );

  String _semanticLabel(AppI18n i18n) {
    final eta = stop.primaryTime;
    final parts = <String>[
      stop.name,
      if (eta != null && !suppressEtaLabel)
        stop.isLiveEta ? eta : i18n.busScheduledDeparture(eta),
      if (isAlightTarget) i18n.alightTargetStopHint,
      if (isLeadStop) i18n.alightLeadStopHint,
    ];
    return parts.join('，');
  }

  Widget _buildEta(AppI18n i18n, ColorScheme cs) {
    final label = stop.primaryTime;
    if (label == null) return const SizedBox.shrink();

    return stop.isLiveEta
        ? _liveEta(cs, label)
        : _scheduledEta(i18n, cs, label);
  }

  Widget _scheduledEta(AppI18n i18n, ColorScheme cs, String label) {
    // A clock is a departure time and is prefixed as such; a service-state
    // word ('末班已過') already reads as one and takes no prefix.
    final isClock = label.contains(':');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isClock)
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Text(
              i18n.busDeparture,
              style: AppTextStyles.bodyVerySmall.copyWith(
                fontSize: 11,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        Text(
          label,
          style: (isClock ? AppTextStyles.memo : AppTextStyles.bodySmall)
              .copyWith(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                fontFeatures: isClock ? AppTextStyles.tabularFigures : null,
              ),
        ),
      ],
    );
  }

  Widget _liveEta(ColorScheme cs, String label) {
    final arriving = stop.state == TimelineStopState.arriving;
    return Text(
      label,
      style: AppTextStyles.timeValue(
        size: 15,
        weight: arriving ? FontWeight.w700 : FontWeight.w600,
        color: arriving ? AppTheme.statusArrivingText : cs.onSurface,
      ),
    );
  }
}

class _ShimmerStopList extends StatelessWidget {
  const _ShimmerStopList({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: StopListTab(
        stops: _skeletonStops,
        scrollController: scrollController,
        flashStopUid: null,
      ),
    );
  }
}

/// Six stops with a countdown on the first two — the shape a route usually
/// arrives in. Fixed values, so the bones never re-measure between frames.
final List<TimelineStop> _skeletonStops = [
  for (var i = 0; i < 6; i++)
    TimelineStop(
      uid: 'skeleton-$i',
      name: BoneMock.chars(i.isEven ? 5 : 4, '囗'),
      primaryTime: '${(i + 1) * 3}',
      isLiveEta: i < 2,
    ),
];
