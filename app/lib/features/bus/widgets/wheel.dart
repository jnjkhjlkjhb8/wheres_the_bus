import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

const double _kAnglePerStation = 2 * pi / 3;

class Wheel extends StatefulWidget {
  const Wheel({
    required this.stops,
    required this.stationOffsets,
    required this.selectedIndex,
    required this.onStationSelected,
    this.scrollController,
    super.key,
  });
  final List<TimelineStop> stops;
  final List<double> stationOffsets;
  final int selectedIndex;
  final ValueChanged<int> onStationSelected;
  final ScrollController? scrollController;

  @override
  State<Wheel> createState() => _WheelState();
}

class _WheelState extends State<Wheel> {
  double _lastAngle = 0;
  double _accDelta = 0;
  late int _currentStation;

  @override
  void initState() {
    super.initState();
    _currentStation = widget.selectedIndex;
  }

  @override
  void didUpdateWidget(Wheel old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) {
      _currentStation = widget.selectedIndex;
    }
  }

  double _angleOf(Offset pos) {
    const center = Offset(125, 125);
    final d = pos - center;
    return atan2(d.dy, d.dx);
  }

  double _angleDiff(double a, double b) {
    var d = a - b;
    if (d > pi) d -= 2 * pi;
    if (d < -pi) d += 2 * pi;
    return d;
  }

  void _onPanStart(DragStartDetails d) {
    _lastAngle = _angleOf(d.localPosition);
    _accDelta = 0;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final newAngle = _angleOf(d.localPosition);
    final delta = _angleDiff(newAngle, _lastAngle);
    _lastAngle = newAngle;
    _accDelta += delta;

    if (_accDelta.abs() >= _kAnglePerStation) {
      final step = _accDelta > 0 ? 1 : -1;
      final next = (_currentStation + step).clamp(0, widget.stops.length - 1);
      if (next != _currentStation) {
        _currentStation = next;
        widget.onStationSelected(next);
        unawaited(HapticFeedback.selectionClick());
      }
      _accDelta = 0;
    } else {
      final sc = widget.scrollController;
      if (sc != null && sc.hasClients) {
        final offsets = widget.stationOffsets;
        final idx = _currentStation;
        final progress = _accDelta / _kAnglePerStation;
        final max = sc.position.maxScrollExtent;
        final from = offsets[idx].clamp(0.0, max);
        double to;
        if (progress > 0 && idx < offsets.length - 1) {
          to = offsets[idx + 1].clamp(0.0, max);
        } else if (progress < 0 && idx > 0) {
          to = offsets[idx - 1].clamp(0.0, max);
        } else {
          to = from;
        }
        sc.jumpTo(from + (to - from) * progress.abs());
      }
    }
  }

  void _onPanEnd(DragEndDetails _) {
    _accDelta = 0;
    final sc = widget.scrollController;
    if (sc != null && sc.hasClients) {
      final max = sc.position.maxScrollExtent;
      final target = widget.stationOffsets[_currentStation].clamp(0.0, max);
      if (MediaQuery.disableAnimationsOf(context)) {
        sc.jumpTo(target);
      } else {
        unawaited(
          sc.animateTo(
            target,
            duration: AppMotion.short,
            curve: AppMotion.easeOut,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 260,
      alignment: Alignment.center,
      color: cs.surfaceContainerLow,
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: CustomPaint(
          size: const Size(250, 250),
          painter: _DialPainter(
            ringColor: cs.surfaceContainerHighest,
            centerColor: cs.surface,
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({required this.ringColor, required this.centerColor});

  final Color ringColor;
  final Color centerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas
      ..drawCircle(center, 125, Paint()..color = ringColor)
      ..drawCircle(center, 50, Paint()..color = centerColor);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.ringColor != ringColor || old.centerColor != centerColor;
}
