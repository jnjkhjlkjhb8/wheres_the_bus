import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';

final RegExp _mapDigits = RegExp(r'\d+');

/// Line colour for a station id: the prefix of the first (primary) line code.
/// Interchange ids combine codes (e.g. 'BL15_BR10'); the first wins.
Color metroLineColor(String id) {
  final code = id.split('_').first.replaceAll(_mapDigits, '');
  switch (code) {
    case 'BL':
      return AppTheme.mrtBL;
    case 'R':
      return AppTheme.mrtR;
    case 'G':
      return AppTheme.mrtG;
    case 'O':
      return AppTheme.mrtO;
    case 'BR':
      return AppTheme.mrtBR;
    case 'Y':
      return AppTheme.mrtY;
    default:
      return AppTheme.mrtBL;
  }
}

class MetroSvgMap extends StatefulWidget {
  const MetroSvgMap({
    required this.onStationTap,
    this.selectedStationId,
    this.stationLabels = const {},
    this.animate = true,
    this.pickAheadIds,
    this.pickBoardId,
    this.pickedStationId,
    super.key,
  });

  final ValueChanged<MetroMapStation> onStationTap;
  final String? selectedStationId;
  final Map<String, String> stationLabels;
  final bool animate;

  final Set<String>? pickAheadIds;

  /// The station the rider boarded at, marked with a single ring.
  final String? pickBoardId;

  /// The 下車站 chosen so far, marked with a double ring. Hollow, always: a
  /// filled marker would sit on top of the station's printed name.
  final String? pickedStationId;

  static const double _mapW = 1080;
  static const double _mapH = 1920;

  /// Slack allowed around the map beyond the viewport edges, so the edge
  /// stations can be dragged clear of the sheet and the top controls.
  static const double _boundaryMargin = 120;

  /// Zoom the map opens at. Below 1 so the network reads as a whole on first
  /// sight instead of filling the viewport edge to edge.
  static const double _initialScale = .8;

  static double _topGutter(BuildContext context) =>
      (MediaQuery.paddingOf(context).top + AppBarMetrics.barHeight) /
      _initialScale;

  /// Starts rasterizing the current theme's map bitmap so it is ready before
  /// the user navigates here — the one-time ~400ms rasterization otherwise
  /// lands in the middle of the push transition. Safe to call repeatedly.
  static void precache(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    unawaited(
      _RasterSvgState.ensure(
        isDark
            ? 'assets/mrt/TRTC_map_dark.svg'
            : 'assets/mrt/TRTC_map_light.svg',
        _RasterSvgState.targetWidthFor(context),
      ),
    );
  }

  /// Live entries in the rasterised-bitmap cache. Each one is a ~20-30MB
  /// GPU texture, so the count is the assertion that eviction still works.
  @visibleForTesting
  static int get rasterCacheSize => _RasterSvgState.cacheSize;

  @override
  State<MetroSvgMap> createState() => _MetroSvgMapState();
}

class _MetroSvgMapState extends State<MetroSvgMap> {
  bool _semanticsReady = false;
  Timer? _deferTimer;

  final _transform = TransformationController();
  bool _framed = false;

  @override
  void initState() {
    super.initState();
    _deferTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _semanticsReady = true);
    });
  }

  @override
  void dispose() {
    _deferTimer?.cancel();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final s = constraints.maxWidth / MetroSvgMap._mapW;
      final mapH = MetroSvgMap._mapH * s;

      // Scale about the horizontal centre, once: after the first frame the
      // transform belongs to the user's pan/zoom.
      if (!_framed) {
        _framed = true;
        const k = MetroSvgMap._initialScale;
        _transform.value = Matrix4.identity()
          ..translateByDouble(constraints.maxWidth * (1 - k) / 2, 0, 0, 1)
          ..scaleByDouble(k, k, k, 1);
      }
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final cs = Theme.of(context).colorScheme;
      final selectedStationId = widget.selectedStationId;

      final selectedStation = selectedStationId != null
          ? metroMapStations.firstWhere(
              (st) => st.id == selectedStationId,
              orElse: () => metroMapStations.first,
            )
          : null;

      int getDelayMs(MetroMapStation station) {
        if (selectedStation == null) return 0;
        final dx = station.x - selectedStation.x;
        final dy = station.y - selectedStation.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        return (dist * 0.25).toInt().clamp(0, 600);
      }

      return InteractiveViewer(
        transformationController: _transform,
        minScale: .45,
        maxScale: 4,
        constrained: false,
        boundaryMargin: const EdgeInsets.all(MetroSvgMap._boundaryMargin),
        child: Padding(
          padding: EdgeInsets.only(top: MetroSvgMap._topGutter(context)),
          child: SizedBox(
            width: constraints.maxWidth,
            height: mapH,
            child: Stack(
              children: [
                Positioned.fill(
                  // Isolates the static map raster from the marker/label
                  // layers above, which animate on selection — without this,
                  // every ping/label frame repaints the whole map bitmap too.
                  child: RepaintBoundary(
                    child: _RasterSvg(
                      asset: isDark
                          ? 'assets/mrt/TRTC_map_dark.svg'
                          : 'assets/mrt/TRTC_map_light.svg',
                    ),
                  ),
                ),
                if (widget.pickAheadIds != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        // Light enough that the map's own labels stay legible:
                        // the wash only has to put the stations this train
                        // never reaches behind the ones it does.
                        color: cs.surface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                if (widget.pickAheadIds case final ahead?)
                  for (final station in metroMapStations)
                    if (ahead.contains(station.id) ||
                        station.id == widget.pickBoardId)
                      _PickRing(
                        x: station.x * s,
                        y: station.y * s,
                        color:
                            station.id == widget.pickedStationId ||
                                station.id == widget.pickBoardId
                            ? cs.onSurface
                            : metroLineColor(station.id),
                        doubleRing: station.id == widget.pickedStationId,
                        haloColor: cs.surface,
                      ),
                for (final station in metroMapStations)
                  if (station.id == selectedStationId)
                    _SelectedMarker(
                      key: ValueKey(selectedStationId),
                      x: station.x * s,
                      y: station.y * s,
                      scale: s,
                      color: metroLineColor(station.id),
                      animate: widget.animate,
                    ),
                _StationHitLayer(
                  // In pick-mode only the stations this train still calls at
                  // answer a tap; everything else is scenery until the pick
                  // ends.
                  stations: widget.pickAheadIds == null
                      ? metroMapStations
                      : metroMapStations
                            .where((st) => widget.pickAheadIds!.contains(st.id))
                            .toList(),
                  scale: s,
                  onStationTap: widget.onStationTap,
                  semanticsReady: _semanticsReady,
                ),
                for (final station in metroMapStations)
                  if (widget.stationLabels[station.id] case final label?)
                    Positioned(
                      left: station.x * s - 24,
                      top: station.y * s - 2,
                      width: 48,
                      child: IgnorePointer(
                        child: _AnimatedLabel(
                          key: ValueKey(station.id),
                          label: label,
                          delayMs: getDelayMs(station),
                          animate: widget.animate,
                          isSelected: station.id == selectedStationId,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _StationHitLayer extends StatefulWidget {
  const _StationHitLayer({
    required this.stations,
    required this.scale,
    required this.onStationTap,
    required this.semanticsReady,
  });

  final List<MetroMapStation> stations;
  final double scale;
  final ValueChanged<MetroMapStation> onStationTap;
  final bool semanticsReady;

  /// Half of the 44×44 minimum touch target.
  static const double hitRadius = 22;

  @override
  State<_StationHitLayer> createState() => _StationHitLayerState();
}

class _StationHitLayerState extends State<_StationHitLayer> {
  MetroMapStation? _pressedStation;

  @visibleForTesting
  MetroMapStation? nearestStation(Offset local) {
    MetroMapStation? nearest;
    var nearestDist = double.infinity;
    for (final station in widget.stations) {
      final dx = station.x * widget.scale - local.dx;
      final dy = station.y * widget.scale - local.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist <= _StationHitLayer.hitRadius && dist < nearestDist) {
        nearest = station;
        nearestDist = dist;
      }
    }
    return nearest;
  }

  void _setPressed(MetroMapStation? station) {
    if (_pressedStation != station) setState(() => _pressedStation = station);
  }

  @override
  Widget build(BuildContext context) {
    const hitRadius = _StationHitLayer.hitRadius;
    final pressed = _pressedStation;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) =>
            _setPressed(nearestStation(details.localPosition)),
        onTapCancel: () => _setPressed(null),
        onTapUp: (details) {
          final station = nearestStation(details.localPosition);
          _setPressed(null);
          if (station != null) widget.onStationTap(station);
        },
        child: Stack(
          children: [
            if (pressed != null)
              Positioned(
                left: pressed.x * widget.scale - hitRadius,
                top: pressed.y * widget.scale - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: metroLineColor(
                        pressed.id,
                      ).withValues(alpha: 0.16),
                    ),
                  ),
                ),
              ),
            if (widget.semanticsReady)
              for (final station in widget.stations)
                Positioned(
                  left: station.x * widget.scale - hitRadius,
                  top: station.y * widget.scale - hitRadius,
                  width: hitRadius * 2,
                  height: hitRadius * 2,
                  child: Semantics(
                    button: true,
                    label: '${station.id} ${station.name}',
                    onTap: () => widget.onStationTap(station),
                    child: const SizedBox.expand(),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _RasterSvg extends StatefulWidget {
  const _RasterSvg({required this.asset});

  final String asset;

  @override
  State<_RasterSvg> createState() => _RasterSvgState();
}

class _RasterSvgState extends State<_RasterSvg> {
  static final Map<String, Future<ui.Image>> _cache = {};
  static final Map<String, int> _holders = {};

  /// The key [ensure] was last asked for. Exempt from eviction even while
  /// unheld: precache() populates it precisely before any widget holds it.
  static String? _liveKey;

  static String _keyFor(String asset, int targetW) => '$asset@$targetW';

  @visibleForTesting
  static int get cacheSize => _cache.length;

  static void _evictUnheld() {
    for (final key in _cache.keys.toList()) {
      if (key == _liveKey) continue;
      if ((_holders[key] ?? 0) > 0) continue;
      final stale = _cache.remove(key);
      // A rasterization that failed has nothing to dispose, and its error
      // was already surfaced to whoever awaited it — swallowing it here
      // keeps eviction from re-raising it into the zone.
      unawaited(
        stale!
            .then((image) => image.dispose())
            .catchError((Object _, StackTrace _) {}),
      );
    }
  }

  ui.Image? _image;

  /// The cache key this state is counted against in [_holders], if any.
  String? _heldKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RasterSvg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset) {
      _image = null;
      _load();
    }
  }

  @override
  void dispose() {
    _release();
    _evictUnheld();
    super.dispose();
  }

  void _release() {
    final key = _heldKey;
    if (key == null) return;
    _heldKey = null;
    final remaining = (_holders[key] ?? 1) - 1;
    if (remaining > 0) {
      _holders[key] = remaining;
    } else {
      _holders.remove(key);
    }
  }

  /// 2× the on-screen physical width keeps labels sharp up to ~2× zoom;
  /// height (map is 1080×1920) stays within the common 4096px texture cap.
  static int targetWidthFor(BuildContext context) =>
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context) *
              2)
          .round()
          .clamp(1080, 2304);

  static Future<ui.Image> ensure(String asset, int targetW) {
    final key = _keyFor(asset, targetW);
    _liveKey = key;
    final cached = _cache[key];
    if (cached != null) {
      _evictUnheld();
      return cached;
    }
    final future = _rasterize(asset, targetW);
    _cache[key] = future;
    _evictUnheld();
    return future;
  }

  void _load() {
    final asset = widget.asset;
    final key = _keyFor(asset, targetWidthFor(context));
    if (key == _heldKey) return;
    _holders.update(key, (n) => n + 1, ifAbsent: () => 1);
    _release();
    _heldKey = key;
    unawaited(
      ensure(asset, targetWidthFor(context)).then((img) {
        if (mounted && _heldKey == key) {
          setState(() => _image = img);
        }
      }),
    );
  }

  static Future<ui.Image> _rasterize(String asset, int targetW) async {
    final info = await vg.loadPicture(SvgAssetLoader(asset), null);
    final scale = targetW / info.size.width;
    final targetH = (info.size.height * scale).round();
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(scale)
      ..drawPicture(info.picture);
    final scaled = recorder.endRecording();
    try {
      // toImageSync keeps the result GPU-resident; toImage returns a host
      // image whose ~37MB texture upload would jank the first on-screen draw.
      return scaled.toImageSync(targetW, targetH);
    } finally {
      scaled.dispose();
      info.picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => _image != null
      ? RawImage(image: _image, fit: BoxFit.fill)
      : const SizedBox.shrink();
}

class _AnimatedLabel extends StatefulWidget {
  const _AnimatedLabel({
    required this.label,
    required this.delayMs,
    required this.animate,
    required this.isSelected,
    required this.color,
    super.key,
  });

  final String label;
  final int delayMs;
  final bool animate;
  final bool isSelected;
  final Color color;

  @override
  State<_AnimatedLabel> createState() => _AnimatedLabelState();
}

class _AnimatedLabelState extends State<_AnimatedLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  Timer? _timer;
  bool _entryPlayed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AppMotion.short,
    );
    _scale = Tween<double>(begin: 0.92, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.easeOut),
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.easeOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_entryPlayed) {
      _entryPlayed = true;
      _playEntry();
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSelected != widget.isSelected) {
      _playEntry();
    }
  }

  void _playEntry() {
    _timer?.cancel();
    _ctrl.value = 0;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (!widget.animate || disableAnimations) {
      _ctrl.value = 1;
      return;
    }
    _timer = Timer(Duration(milliseconds: widget.delayMs), () {
      if (mounted) {
        unawaited(_ctrl.forward());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: FadeTransition(
        opacity: _opacity,
        child: Text(
          widget.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 4,
            fontWeight: FontWeight.w800,
            color: widget.color,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _SelectedMarker extends StatefulWidget {
  const _SelectedMarker({
    required this.x,
    required this.y,
    required this.scale,
    required this.color,
    required this.animate,
    super.key,
  });

  final double x;
  final double y;
  final double scale;
  final Color color;
  final bool animate;

  // SVG-unit geometry (glyph radius is 14). The ring clears the glyph; the
  // ping expands from the ring out to [_pingMaxUnits].
  static const double _haloUnits = 26;
  static const double _ringUnits = 20;
  static const double _ringStrokeUnits = 4;
  static const double _pingStartUnits = 20;
  static const double _pingMaxUnits = 52;
  static const double _pingStrokeUnits = 2.5;

  @override
  State<_SelectedMarker> createState() => _SelectedMarkerState();
}

class _SelectedMarkerState extends State<_SelectedMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _motionSynced = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant _SelectedMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _motionSynced = false;
      _syncMotion();
    }
  }

  void _syncMotion() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (!widget.animate || disableAnimations) {
      _ctrl.value = 1;
      _motionSynced = true;
      return;
    }
    if (!_motionSynced) {
      _motionSynced = true;
      unawaited(_ctrl.forward());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final color = widget.color;
    final boxHalf = _SelectedMarker._pingMaxUnits * s;

    // Box is sized to the ping's outer bound so the expanding ring isn't
    // clipped; the static halo + ring stay centred within it.
    return Positioned(
      left: widget.x - boxHalf,
      top: widget.y - boxHalf,
      width: boxHalf * 2,
      height: boxHalf * 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            final t = AppMotion.easeOut.transform(_ctrl.value);
            final pingRadius =
                (_SelectedMarker._pingStartUnits +
                    (_SelectedMarker._pingMaxUnits -
                            _SelectedMarker._pingStartUnits) *
                        t) *
                s;
            return Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.square(pingRadius * 2),
                  painter: _RingPainter(
                    color: color,
                    opacity: (1 - _ctrl.value) * 0.4,
                    strokeWidth: _SelectedMarker._pingStrokeUnits * s,
                  ),
                ),
                child!,
              ],
            );
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: _SelectedMarker._haloUnits * 2 * s,
                height: _SelectedMarker._haloUnits * 2 * s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.14),
                ),
              ),
              CustomPaint(
                size: Size.square(_SelectedMarker._ringUnits * 2 * s),
                painter: _RingPainter(
                  color: color,
                  opacity: 1,
                  strokeWidth: _SelectedMarker._ringStrokeUnits * s,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stroke ring used both for the static selection ring and the expanding,
/// fading locate-me "ping".
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.color,
    required this.opacity,
    required this.strokeWidth,
  });

  final Color color;
  final double opacity;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    canvas.drawCircle(
      Offset(r, r),
      r - strokeWidth / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.opacity != opacity ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

class _PickRing extends StatelessWidget {
  const _PickRing({
    required this.x,
    required this.y,
    required this.color,
    required this.doubleRing,
    required this.haloColor,
  });

  final double x;
  final double y;
  final Color color;
  final bool doubleRing;
  final Color haloColor;

  static const double _size = 16;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: x - _size / 2,
      top: y - _size / 2,
      width: _size,
      height: _size,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: doubleRing ? 3 : 2),
            boxShadow: doubleRing
                ? [
                    BoxShadow(color: haloColor, spreadRadius: 2),
                    BoxShadow(color: color, spreadRadius: 4),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
