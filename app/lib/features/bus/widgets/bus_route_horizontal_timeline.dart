part of '../view/bus_route_screen.dart';

// Same node the vertical stop list draws for "the vehicle is in this segment"
// (TimelineVehicleMarker): one marker, one look, whichever axis it is on.
const _arrowSize = 17.0;

const _tlCellHeight = 120.0;

// Vertical centre of the stop dot / rail; shared by the painter and the
// vehicle-arrow overlay below so they stay aligned.
const _tlDotCenterY = 52.0;

// Remaining vertical layout of a cell, tuned to fit _tlCellHeight exactly —
// the fare-zone band and its label used to sit below row 120 and never paint.
const _tlEtaLabelTop = 70.0;
const _tlBandTop = 88.0;
const _tlBandHeight = 14.0;
const _tlBandLabelTop = 102.0;

// Public only so tests can mount the strip from stop fixtures instead of the
// whole route screen.
class HorizontalRouteTimeline extends StatelessWidget {
  const HorizontalRouteTimeline({
    required this.stops,
    required this.direction,
    required this.controller,
    required this.flashStopUid,
    this.onStopTap,
    this.onVehicleTap,
    super.key,
  });

  final List<TimelineStop> stops;
  final int direction;
  final ScrollController controller;

  /// The stop briefly highlighted after its map marker was tapped.
  final String? flashStopUid;

  /// A cell tap is a "show me this one": the map centres on
  /// that stop's marker. Same for the vehicle arrow, which also selects the
  /// bus so its bubble opens.
  final void Function(String uid)? onStopTap;
  final void Function(String plate)? onVehicleTap;

  @override
  Widget build(BuildContext context) {
    // Same derivation the vertical stop list uses: a marker at index i means
    // the vehicle sits in the segment between stop i-1 and stop i. The feed
    // carries no position along that segment, so it rides the middle.
    final markers = busVehicleMarkerIndices(stops);
    return SizedBox(
      height: _tlCellHeight,
      child: ListView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _kTlPadding),
        itemCount: stops.length,
        itemBuilder: (context, i) {
          return _buildCell(context, i, markers);
        },
      ),
    );
  }

  Widget _buildCell(BuildContext context, int i, Set<int> markers) {
    final cs = Theme.of(context).colorScheme;
    final stop = stops[i];
    // A marker-tap flash reads the same as the live/active stop.
    final isEmphasised = stop.active || stop.uid == flashStopUid;

    final prevStop = _neighbor(i - 1);
    final nextStop = _neighbor(i + 1);
    final hasVehicle = markers.contains(i);
    final vehiclePlate = hasVehicle ? stop.plate : '';

    final dotColor = _dotColor(stop, cs, isEmphasised);

    final cell = SizedBox(
      width: _kTlCellWidth,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            right: 0,
            child: CustomPaint(
              painter: _painter(i, stop, cs, dotColor),
            ),
          ),

          if (hasVehicle) ..._vehicleWidgets(context, vehiclePlate, cs),

          _stopName(stop, cs),

          Positioned(
            top: _tlEtaLabelTop,
            left: 4,
            right: 4,
            child: _buildEtaLabel(context, stop, cs),
          ),

          ..._bufferBand(context, stop, prevStop, nextStop, cs),
        ],
      ),
    );

    return _normalCell(cell, stop);
  }

  TimelineStop? _neighbor(int index) =>
      index >= 0 && index < stops.length ? stops[index] : null;

  Widget _normalCell(Widget cell, TimelineStop stop) => onStopTap == null
      ? cell
      : Pressable(onTap: () => onStopTap!(stop.uid), child: cell);

  Color _dotColor(
    TimelineStop stop,
    ColorScheme cs,
    bool emphasised,
  ) {
    // Inactive dots need graphical contrast even without a live ETA state.
    return switch (stop.state) {
      TimelineStopState.arriving => AppTheme.statusArriving,
      TimelineStopState.approaching => AppTheme.statusApproach,
      TimelineStopState.none => emphasised ? cs.primary : cs.onSurfaceVariant,
    };
  }

  bool _activeConnection(TimelineStop stop, TimelineStop? neighbor) =>
      stop.active && neighbor?.active == true;

  bool _bufferConnection(TimelineStop stop, TimelineStop? neighbor) =>
      stop.isBuffer && neighbor?.isBuffer == true;

  _HorizontalTimelinePainter _painter(
    int i,
    TimelineStop stop,
    ColorScheme cs,
    Color dotColor,
  ) {
    final previous = i > 0 ? stops[i - 1] : null;
    final next = i < stops.length - 1 ? stops[i + 1] : null;
    return _HorizontalTimelinePainter(
      isFirst: i == 0,
      isLast: i == stops.length - 1,
      leftIsBuffer: _bufferConnection(stop, previous),
      rightIsBuffer: _bufferConnection(stop, next),
      lineColor: cs.onSurfaceVariant,
      dotColor: dotColor,
      surfaceColor: cs.surface,
      activeColor: cs.primary,
      isLeftActive: _activeConnection(stop, previous),
      isRightActive: _activeConnection(stop, next),
      stopState: stop.state,
      isActiveStop: stop.active,
    );
  }

  List<Widget> _vehicleWidgets(
    BuildContext context,
    String vehiclePlate,
    ColorScheme cs,
  ) => [
    Positioned(
      left: 0,
      top: _tlDotCenterY - _arrowSize / 2,
      child: Pressable(
        // A marker the feed gave no plate for has nothing to
        // select — same rule the stop list's swipe row applies.
        enabled: vehiclePlate.isNotEmpty,
        onTap: () => onVehicleTap?.call(vehiclePlate),
        semanticLabel: AppI18n.of(context).busVehicleHere,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.onSurface,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: _arrowSize,
            // Points along the axis, i.e. the direction of
            // travel — the list's marker points down for the
            // same reason.
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 11,
              color: cs.surface,
            ),
          ),
        ),
      ),
    ),

    // Plate rides just above its own arrow. It used to be painted
    // by the CustomPaint underneath, which put it behind the stop
    // name — on a two-line name it was never visible.
    if (vehiclePlate.isNotEmpty)
      Positioned(
        left: 0,
        top: _tlDotCenterY - _arrowSize / 2 - 13,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(
                AppTheme.radiusChip,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                vehiclePlate,
                style: AppTextStyles.memo.copyWith(
                  fontSize: 9,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                  fontFeatures: _tnum,
                ),
              ),
            ),
          ),
        ),
      ),
  ];

  Widget _stopName(TimelineStop stop, ColorScheme cs) => Positioned(
    top: 8,
    left: 8,
    right: 8,
    child: Text(
      stop.name,
      style: AppTextStyles.bodySmall.copyWith(
        fontWeight: stop.active ? FontWeight.w600 : FontWeight.w400,
        color: stop.active ? cs.onSurface : cs.onSurfaceVariant,
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
  );

  List<Widget> _bufferBand(
    BuildContext context,
    TimelineStop stop,
    TimelineStop? previous,
    TimelineStop? next,
    ColorScheme cs,
  ) {
    if (!stop.isBuffer) return const [];
    final isBandStart = previous?.isBuffer != true;
    final isBandEnd = next?.isBuffer != true;
    return [
      Positioned(
        top: _tlBandTop,
        left: _bandInset(isBandStart),
        right: _bandInset(isBandEnd),
        height: _tlBandHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.horizontal(
              left: _bandRadius(isBandStart),
              right: _bandRadius(isBandEnd),
            ),
          ),
        ),
      ),

      if (isBandStart)
        Positioned(
          top: _tlBandLabelTop,
          left: 8,
          right: 0,
          child: Text(
            AppI18n.of(context).busBufferZone,
            style: AppTextStyles.bodyVerySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
    ];
  }

  double _bandInset(bool edge) => edge ? 5 : 0;
  Radius _bandRadius(bool edge) => Radius.circular(edge ? 9 : 0);

  Widget _buildEtaLabel(
    BuildContext context,
    TimelineStop stop,
    ColorScheme cs,
  ) {
    return switch (timelineEtaLabel(stop)) {
      TimelineEtaLabel.arriving => Center(
        child: Text(
          AppI18n.of(context).etaArriving,
          style: AppTextStyles.memo.copyWith(
            color: AppTheme.statusArriving,
            fontWeight: FontWeight.w700,
            fontSize: 10,
            fontFeatures: _tnum,
          ),
          textAlign: TextAlign.center,
        ),
      ),
      TimelineEtaLabel.approaching => Center(
        child: Text(
          AppI18n.of(context).etaApproaching,
          style: AppTextStyles.memo.copyWith(
            color: AppTheme.statusApproach,
            fontWeight: FontWeight.w700,
            fontSize: 10,
            fontFeatures: _tnum,
          ),
          textAlign: TextAlign.center,
        ),
      ),
      TimelineEtaLabel.countdown ||
      TimelineEtaLabel.countdownSoon => _countdownLabel(stop, cs),
      TimelineEtaLabel.none => const SizedBox.shrink(),
    };
  }

  Widget _countdownLabel(TimelineStop stop, ColorScheme cs) {
    final isArrivingSoon =
        timelineEtaLabel(stop) == TimelineEtaLabel.countdownSoon;
    final textColor = isArrivingSoon
        ? AppTheme.statusArriving
        : (stop.active ? cs.primary : cs.onSurface);
    return Center(
      child: Text(
        stop.primaryTime!,
        style: AppTextStyles.memo.copyWith(
          color: textColor,
          fontWeight: isArrivingSoon ? FontWeight.w700 : FontWeight.w600,
          fontSize: 11,
          fontFeatures: _tnum,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _HorizontalTimelinePainter extends CustomPainter {
  const _HorizontalTimelinePainter({
    required this.isFirst,
    required this.isLast,
    required this.leftIsBuffer,
    required this.rightIsBuffer,
    required this.lineColor,
    required this.dotColor,
    required this.surfaceColor,
    required this.activeColor,
    required this.isLeftActive,
    required this.isRightActive,
    required this.stopState,
    required this.isActiveStop,
  });

  final bool isFirst;
  final bool isLast;
  final bool leftIsBuffer;
  final bool rightIsBuffer;
  final Color lineColor;
  final Color dotColor;

  /// Surface behind the timeline; fills the hollow centre of each stop dot so
  /// the ring reads correctly in both light and dark themes.
  final Color surfaceColor;
  final Color activeColor;
  final bool isLeftActive;
  final bool isRightActive;
  final TimelineStopState stopState;
  final bool isActiveStop;

  @override
  void paint(Canvas canvas, Size size) {
    const cy = _tlDotCenterY;
    final cx = size.width / 2;
    _paintRail(canvas, size);

    _paintBufferMarker(canvas, size);

    // Every stop is a plain hollow dot; the live state (進站中 green, 即將進站
    // amber) is carried by the ring colour, and the approaching stop's radar
    // ping is drawn as an animated widget in the Stack above — no static halo.
    canvas
      ..drawCircle(
        Offset(cx, cy),
        7,
        Paint()..color = surfaceColor,
      )
      ..drawCircle(
        Offset(cx, cy),
        7,
        Paint()
          ..color = dotColor
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );
  }

  Paint _railPaint(bool active) => Paint()
    ..color = active ? activeColor : lineColor
    ..strokeWidth = 8
    ..strokeCap = StrokeCap.butt;

  void _paintRail(Canvas canvas, Size size) {
    // Butt caps (not round) so each cell's half-segments abut the neighbours
    // into one continuous rail instead of reading as separate rounded stubs.

    const cy = _tlDotCenterY;
    final cx = size.width / 2;

    if (!isFirst) {
      canvas.drawLine(
        const Offset(0, cy),
        Offset(cx, cy),
        _railPaint(isLeftActive),
      );
    }

    if (!isLast) {
      canvas.drawLine(
        Offset(cx, cy),
        Offset(size.width, cy),
        _railPaint(isRightActive),
      );
    }
  }

  void _paintBufferMarker(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const cy = _tlDotCenterY;
    if (rightIsBuffer && !isLast) {
      final mx = cx + (size.width - cx) / 2;
      final paintDotted = Paint()
        ..color = lineColor.withValues(alpha: 0.6)
        ..strokeWidth = 1.5;

      const startY = cy + 6.0;
      const endY = 70.0;
      var y = startY;
      while (y < endY) {
        canvas.drawCircle(Offset(mx, y), 1, paintDotted);
        y += 4.0;
      }
    }
  }

  @override
  bool shouldRepaint(_HorizontalTimelinePainter old) =>
      (
        isFirst,
        isLast,
        leftIsBuffer,
        rightIsBuffer,
        lineColor,
        dotColor,
        surfaceColor,
        activeColor,
        isLeftActive,
        isRightActive,
        stopState,
        isActiveStop,
      ) !=
      (
        old.isFirst,
        old.isLast,
        old.leftIsBuffer,
        old.rightIsBuffer,
        old.lineColor,
        old.dotColor,
        old.surfaceColor,
        old.activeColor,
        old.isLeftActive,
        old.isRightActive,
        old.stopState,
        old.isActiveStop,
      );
}
