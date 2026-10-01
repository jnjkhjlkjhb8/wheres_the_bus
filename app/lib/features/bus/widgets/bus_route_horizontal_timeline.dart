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

class _HorizontalRouteTimeline extends StatelessWidget {
  const _HorizontalRouteTimeline({
    required this.stops,
    required this.direction,
    required this.controller,
    required this.flashStopUid,
    this.picking = false,
    this.pinnedNextStopIndex,
    this.targetUid,
    this.onPickStop,
    this.onStopTap,
    this.onVehicleTap,
  });

  final List<TimelineStop> stops;
  final int direction;
  final ScrollController controller;

  /// The stop briefly highlighted after its map marker was tapped.
  final String? flashStopUid;

  /// Pick-mode: stops the pinned bus hasn't reached are tappable alight
  /// targets; passed stops dim and ignore taps.
  final bool picking;
  final int? pinnedNextStopIndex;
  final String? targetUid;
  final void Function(String uid)? onPickStop;

  /// Outside pick-mode a cell tap is a "show me this one": the map centres on
  /// that stop's marker. Same for the vehicle arrow, which also selects the
  /// bus so its bubble opens.
  final void Function(String uid)? onStopTap;
  final void Function(String plate)? onVehicleTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
          final stop = stops[i];
          // A marker-tap flash reads the same as the live/active stop.
          final isEmphasised = stop.active || stop.uid == flashStopUid;

          // Pick-mode: the pinned bus's next stop onward are tappable alight
          // targets; the chosen one carries an ink ring, and passed stops dim.
          final isTarget = picking && stop.uid == targetUid;
          final isPassed = picking && !isAlightTarget(i, pinnedNextStopIndex);
          final prevStop = i > 0 ? stops[i - 1] : null;
          final nextStop = i < stops.length - 1 ? stops[i + 1] : null;
          final isFirst = i == 0;
          final isLast = i == stops.length - 1;

          final leftIsBuffer = stop.isBuffer && i > 0 && stops[i - 1].isBuffer;
          final rightIsBuffer =
              stop.isBuffer && nextStop != null && nextStop.isBuffer;

          // Fare zone: only the 緩衝區 (buffer) run gets a band. Contiguous
          // buffer stops render one connected strip with rounded ends and a
          // single 緩衝區 label at the run's head; every other stop draws none.
          final showBand = stop.isBuffer;
          final isBandStart =
              showBand && (prevStop == null || !prevStop.isBuffer);
          final isBandEnd =
              showBand && (nextStop == null || !nextStop.isBuffer);

          final hasVehicle = markers.contains(i);
          final vehiclePlate = hasVehicle ? stop.plate : '';

          // cs.outline is ~1.7:1 against the sheet surface, under the 3:1 WCAG
          // 1.4.11 floor for a meaningful graphical object; onSurfaceVariant
          // clears it in both themes while reading as restrained, not active.
          var dotColor = cs.onSurfaceVariant;
          if (stop.state == TimelineStopState.arriving) {
            dotColor = AppTheme.statusArriving;
          } else if (stop.state == TimelineStopState.approaching) {
            dotColor = AppTheme.statusApproach;
          } else if (isEmphasised) {
            dotColor = cs.primary;
          }
          if (isTarget) dotColor = cs.onSurface;

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
                    painter: _HorizontalTimelinePainter(
                      isFirst: isFirst,
                      isLast: isLast,
                      leftIsBuffer: leftIsBuffer,
                      rightIsBuffer: rightIsBuffer,
                      // cs.outlineVariant at the old 0.4 alpha read as ~1.05:1
                      // on the sheet surface (rail read as invisible); the
                      // painter now uses this at full strength.
                      lineColor: cs.onSurfaceVariant,
                      dotColor: dotColor,
                      surfaceColor: cs.surface,
                      activeColor: cs.primary,
                      isLeftActive:
                          stop.active && (i > 0 && stops[i - 1].active),
                      isRightActive:
                          stop.active && (nextStop != null && nextStop.active),
                      stopState: stop.state,
                      isActiveStop: stop.active,
                      isTarget: isTarget,
                    ),
                  ),
                ),

                if (hasVehicle)
                  Positioned(
                    left: 0,
                    top: _tlDotCenterY - _arrowSize / 2,
                    child: Pressable(
                      // A marker the feed gave no plate for has nothing to
                      // select — same rule the stop list's swipe row applies.
                      enabled: !picking && vehiclePlate.isNotEmpty,
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
                if (hasVehicle && vehiclePlate.isNotEmpty)
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

                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Text(
                    stop.name,
                    style: AppTextStyles.bodySmall.copyWith(
                      fontWeight: stop.active
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: stop.active ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                Positioned(
                  top: _tlEtaLabelTop,
                  left: 4,
                  right: 4,
                  child: _buildEtaLabel(context, stop, cs),
                ),

                if (showBand)
                  Positioned(
                    top: _tlBandTop,
                    left: isBandStart ? 5 : 0,
                    right: isBandEnd ? 5 : 0,
                    height: _tlBandHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(isBandStart ? 9 : 0),
                          right: Radius.circular(isBandEnd ? 9 : 0),
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
              ],
            ),
          );

          if (!picking) {
            return onStopTap == null
                ? cell
                : Pressable(onTap: () => onStopTap!(stop.uid), child: cell);
          }
          if (isPassed) {
            return Opacity(
              opacity: 0.35,
              child: IgnorePointer(child: cell),
            );
          }
          return Pressable(
            onTap: () => onPickStop?.call(stop.uid),
            child: cell,
          );
        },
      ),
    );
  }

  Widget _buildEtaLabel(
    BuildContext context,
    TimelineStop stop,
    ColorScheme cs,
  ) {
    switch (timelineEtaLabel(stop)) {
      case TimelineEtaLabel.arriving:
        return Center(
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
        );
      case TimelineEtaLabel.approaching:
        return Center(
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
        );
      case TimelineEtaLabel.countdown:
      case TimelineEtaLabel.countdownSoon:
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
      case TimelineEtaLabel.none:
        return const SizedBox.shrink();
    }
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
    this.isTarget = false,
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

  /// Whether this stop is the chosen alight target in pick-mode; draws an ink
  /// ring around the dot.
  final bool isTarget;

  @override
  void paint(Canvas canvas, Size size) {
    // Butt caps (not round) so each cell's half-segments abut the neighbours
    // into one continuous rail instead of reading as separate rounded stubs.
    final paintLineLeft = Paint()
      ..color = isLeftActive ? activeColor : lineColor
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.butt;

    final paintLineRight = Paint()
      ..color = isRightActive ? activeColor : lineColor
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.butt;

    const cy = _tlDotCenterY;
    final cx = size.width / 2;

    if (!isFirst) {
      canvas.drawLine(const Offset(0, cy), Offset(cx, cy), paintLineLeft);
    }

    if (!isLast) {
      canvas.drawLine(Offset(cx, cy), Offset(size.width, cy), paintLineRight);
    }

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

    final borderPaint = Paint()
      ..color = isActiveStop ? activeColor : lineColor.withValues(alpha: 0.8)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

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
        borderPaint..color = dotColor,
      );

    // Pick-mode: an ink ring marks the chosen alight target.
    if (isTarget) {
      canvas.drawCircle(
        Offset(cx, cy),
        12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = dotColor,
      );
    }
  }

  @override
  bool shouldRepaint(_HorizontalTimelinePainter old) =>
      old.isFirst != isFirst ||
      old.isLast != isLast ||
      old.leftIsBuffer != leftIsBuffer ||
      old.rightIsBuffer != rightIsBuffer ||
      old.lineColor != lineColor ||
      old.dotColor != dotColor ||
      old.surfaceColor != surfaceColor ||
      old.activeColor != activeColor ||
      old.isLeftActive != isLeftActive ||
      old.isRightActive != isRightActive ||
      old.stopState != stopState ||
      old.isActiveStop != isActiveStop ||
      old.isTarget != isTarget;
}
