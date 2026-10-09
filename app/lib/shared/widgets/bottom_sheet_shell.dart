import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';

abstract final class AppSheetSnap {
  /// Viewport fractions backing each detent — also the clamp bounds a page
  /// hands to [carriedSheetOffset].
  static const peekFrac = 0.25;
  static const halfFrac = 0.5;
  static const tallFrac = 0.85;

  static const double fullInset = AppBarMetrics.floatingTop;

  /// Map/list glancing height — the resting detent for map-front pages, and
  /// the floor of every grid: the sheet never gets smaller than this.
  static const peek = SheetOffset.proportionalToViewport(peekFrac);

  /// The default open height for content-led pages.
  static const half = SheetOffset.proportionalToViewport(halfFrac);

  /// Tall-but-not-full: forms and detail views that open large, and metro's
  /// capped max (keeps the line map peeking above the sheet).
  static const tall = SheetOffset.proportionalToViewport(tallFrac);

  static const full = TopInsetSheetOffset(fullInset);

  static const flingSpeed = 600.0;

  /// The standard three-detent grid used by every page.
  static const grid = SheetSnapGrid(
    snaps: [peek, half, full],
    minFlingSpeed: flingSpeed,
  );
}

@immutable
class TopInsetSheetOffset implements SheetOffset {
  const TopInsetSheetOffset(this.inset);

  /// Gap left between the top of the safe area and the sheet's top edge.
  final double inset;

  @override
  double resolve(ViewportLayout metrics) => math.max(
    0,
    metrics.viewportSize.height - metrics.viewportPadding.top - inset,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TopInsetSheetOffset &&
          runtimeType == other.runtimeType &&
          inset == other.inset);

  @override
  int get hashCode => Object.hash(runtimeType, inset);

  @override
  String toString() => 'TopInsetSheetOffset(inset: $inset)';
}

extension SheetControllerMotion on SheetController {
  Future<void> animateToDetent(SheetOffset to, {required bool reduced}) =>
      animateTo(
        to,
        duration: reduced ? const Duration(milliseconds: 1) : AppMotion.sheet,
      );
}

final _sheetSpring = ClampingSheetPhysics(spring: AppMotion.spring);

double carriedFraction({
  required double offset,
  required double viewportHeight,
  required double min,
  required double max,
  required double fallback,
}) {
  if (viewportHeight <= 0) return fallback.clamp(min, max);
  return (offset / viewportHeight).clamp(min, max);
}

/// [carriedFraction] read from a live [controller], as a [SheetOffset] ready
/// to hand to a sibling sheet's `initialOffset`.
SheetOffset carriedSheetOffset(
  SheetController? controller, {
  required double min,
  required SheetOffset max,
  required double fallback,
}) {
  final metrics = controller?.metrics;
  final viewportHeight = metrics?.viewportSize.height ?? 0;
  // The ceiling is resolved against the live layout rather than passed as a
  // fraction: `max` is the same object the sheet actually stops at, so the
  // carried height can never be clamped to a height the grid would not allow.
  final maxFrac = metrics == null || viewportHeight <= 0
      ? 1.0
      : max.resolve(metrics) / viewportHeight;
  return SheetOffset.proportionalToViewport(
    carriedFraction(
      offset: metrics?.offset ?? 0,
      viewportHeight: viewportHeight,
      min: min,
      max: maxFrac,
      fallback: fallback,
    ),
  );
}

class CarryBackSnapGrid extends NavigatorObserver implements SheetSnapGrid {
  CarryBackSnapGrid({required this.controller, this.base = AppSheetSnap.grid});

  final SheetController controller;

  /// The grid the carried height is snapped against — the page's usual detents.
  final SheetSnapGrid base;

  /// Sheet offset (px) read when the running pop started, or null when no pop
  /// is in flight — which is what leaves every ordinary drag alone, since those
  /// already pass the live offset.
  double? _carried;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _carried = null;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final offset = controller.metrics?.offset;
    final animation = route is TransitionRoute ? route.animation : null;
    if (offset == null || animation == null) return;
    _carried = offset;
    // Dropped once the popped route's animation comes to rest: dismissed for a
    // pop that ran through, completed for a back-swipe the rider let go of with
    // the route still there. Anything still moving is the pop being carried.
    void clearWhenSettled(AnimationStatus status) {
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return;
      }
      animation.removeStatusListener(clearWhenSettled);
      _carried = null;
    }

    animation.addStatusListener(clearWhenSettled);
  }

  @override
  SheetOffset getSnapOffset(
    ViewportLayout layout,
    double offset,
    double velocity,
  ) => base.getSnapOffset(layout, _carried ?? offset, velocity);

  @override
  (SheetOffset, SheetOffset) getBoundaries(ViewportLayout layout) =>
      base.getBoundaries(layout);
}

class CurrentPageSheetTicks extends ChangeNotifier {
  CurrentPageSheetTicks({required this.source, required this.isCurrent}) {
    source.addListener(_onTick);
  }

  /// Usually the page's [SheetController].
  final Listenable source;

  /// Whether the page these ticks drive is the visible one.
  final ValueGetter<bool> isCurrent;

  void _onTick() {
    if (isCurrent()) notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(_onTick);
    super.dispose();
  }
}

class AppSheet extends StatefulWidget {
  const AppSheet({
    required this.child,
    this.controller,
    this.initialOffset = AppSheetSnap.half,
    this.snapGrid = AppSheetSnap.grid,
    this.color,
    super.key,
  }) : navigator = null;

  /// The multi-page variant: the sheet hosts its own [Navigator] and each
  /// [PagedSheetRoute] carries its own detents, so [initialOffset] and
  /// [snapGrid] are the routes' business rather than this widget's.
  const AppSheet.paged({
    required Navigator this.navigator,
    this.controller,
    this.color,
    super.key,
  }) : child = const SizedBox.shrink(),
       initialOffset = AppSheetSnap.half,
       snapGrid = AppSheetSnap.grid;

  final Widget child;

  final SheetController? controller;
  final SheetOffset initialOffset;
  final SheetSnapGrid snapGrid;

  /// Defaults to `surfaceContainerLow`; pages override only when the sheet
  /// sits on a surface that would otherwise blend into it.
  final Color? color;

  final Navigator? navigator;

  @override
  State<AppSheet> createState() => _AppSheetState();
}

class _AppSheetState extends State<AppSheet> {
  /// Only created when the page didn't bring its own.
  SheetController? _ownController;

  SheetController get _controller =>
      widget.controller ?? (_ownController ??= SheetController());

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final decoration = MaterialSheetDecoration(
      size: SheetSize.stretch,
      color: widget.color ?? cs.surfaceContainerLow,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppTheme.radiusBottomSheet),
      ),
      clipBehavior: Clip.antiAlias,
    );
    final navigator = widget.navigator;
    return SheetViewport(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SheetEdgeGestureDetector(
        child: navigator == null
            ? Sheet(
                controller: _controller,
                initialOffset: widget.initialOffset,
                snapGrid: widget.snapGrid,
                // No bounce past the end detents: the sheet is the page's
                // primary surface, and overshoot there reads as the page
                // itself coming loose.
                physics: _sheetSpring,
                scrollConfiguration: const SheetScrollConfiguration(),
                decoration: decoration,
                child: widget.child,
              )
            : PagedSheet(
                controller: _controller,
                physics: _sheetSpring,
                decoration: decoration,
                navigator: navigator,
              ),
      ),
    );
  }
}

class BottomSheetShell extends StatefulWidget {
  const BottomSheetShell({
    required this.child,
    this.initialOffset = AppSheetSnap.half,
    this.minOffset = AppSheetSnap.peek,
    this.maxOffset = AppSheetSnap.full,
    super.key,
  });

  final Widget child;
  final SheetOffset initialOffset;
  final SheetOffset minOffset;
  final SheetOffset maxOffset;

  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    SheetOffset initialOffset = AppSheetSnap.half,
    SheetOffset minOffset = AppSheetSnap.peek,
    SheetOffset maxOffset = AppSheetSnap.full,
  }) {
    return Navigator.of(context).push(
      ModalSheetRoute<T>(
        viewportBuilder: (context, child) => SheetViewport(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: child,
        ),
        builder: (_) => BottomSheetShell(
          initialOffset: initialOffset,
          minOffset: minOffset,
          maxOffset: maxOffset,
          child: child,
        ),
      ),
    );
  }

  @override
  State<BottomSheetShell> createState() => _BottomSheetShellState();
}

class _BottomSheetShellState extends State<BottomSheetShell> {
  late final SheetController _controller = SheetController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _buildSheet(context, cs);
  }

  Widget _buildSheet(BuildContext context, ColorScheme cs) {
    return Sheet(
      controller: _controller,
      initialOffset: widget.initialOffset,
      snapGrid: SheetSnapGrid(
        snaps: [widget.minOffset, widget.initialOffset, widget.maxOffset],
        minFlingSpeed: AppSheetSnap.flingSpeed,
      ),
      physics: _sheetSpring,
      scrollConfiguration: const SheetScrollConfiguration(),
      decoration: MaterialSheetDecoration(
        size: SheetSize.stretch,
        color: cs.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusBottomSheet),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [const SheetDragHandle(), widget.child],
      ),
    );
  }
}

class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key});

  static const _squash = 0.25;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final load = _SheetFloorScope.of(context);
    return Semantics(
      label: AppI18n.of(context).commonDragToResize,
      child: SizedBox(
        width: double.infinity,
        height: 28,
        child: Center(
          // Scaled rather than resized: the handle deforms on every frame of
          // the pull, and a transform keeps that off the layout path.
          child: Transform.scale(
            scaleX: 1 + _squash * load,
            scaleY: 1 - _squash * load,
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                // cs.outline is too low-contrast against the dark sheet
                // surface (~1.45:1); onSurfaceVariant at partial opacity keeps
                // the handle restrained while staying visible in both themes.
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SheetEdgeGestureDetector extends StatefulWidget {
  const SheetEdgeGestureDetector({required this.child, super.key});

  final Widget child;

  @override
  State<SheetEdgeGestureDetector> createState() =>
      _SheetEdgeGestureDetectorState();
}

class _SheetEdgeGestureDetectorState extends State<SheetEdgeGestureDetector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _overflow = AnimationController.unbounded(
    vsync: this,
  );

  /// Whether the sheet is currently held against its floor by a live pull;
  /// false once the rider lets go, so the spring-back does not read as more
  /// pull.
  bool _onFloor = false;

  /// Whether the rider's finger is still on the sheet. The give belongs to a
  /// live drag, so a cancelled one — the arena can take the gesture away
  /// mid-pull — hands the sheet straight back to its spring.
  bool _dragging = false;

  /// How far the sheet can be pushed below its lowest detent, however hard the
  /// rider pulls. Deep enough to read as ground given rather than as a jitter,
  /// shallow enough that the sheet plainly is not going anywhere.
  static const _maxFloorGivePx = 28.0;

  /// The share of the finger the sheet follows in the *first* pixels past the
  /// bottom detent, before the resistance builds. Apple's rubber-band constant.
  static const _floorResistance = 0.55;

  /// Below this the give is invisible, so it is treated as settled rather than
  /// re-sprung: a spring lands arbitrarily close to zero, never exactly on it.
  static const _settledPx = 0.5;

  static double _rubberBand(double overshoot) =>
      (overshoot * _maxFloorGivePx * _floorResistance) /
      (_maxFloorGivePx + _floorResistance * overshoot);

  /// Whether [overflow] is the sheet refusing to go any lower. Overflow is
  /// signed — positive past the top detent, negative past the bottom one — and
  /// only the bottom is this widget's business.
  bool _isFloor(SheetMetrics metrics, double overflow) =>
      overflow < 0 && (metrics.offset - metrics.minOffset).abs() < 1.0;

  void _onFloorOverflow(double overflow) {
    // Assigning `value` also stops a spring-back still in flight, which is
    // what lets the rider catch the sheet on its way home and keep pulling
    // from where it is.
    final from = _onFloor ? _overflow.value : 0.0;
    _overflow.value = from + overflow.abs();
    _onFloor = true;
  }

  void _cleanup({double velocity = 0}) {
    _onFloor = false;
    // Guarded on `isAnimating` because a drag past a detent reports "no
    // overflow" on every frame it is back within bounds; restarting the spring
    // on each of those would freeze it at its first frame.
    if (_overflow.value > _settledPx && !_overflow.isAnimating) {
      unawaited(
        _overflow.animateWith(
          SpringSimulation(AppMotion.spring, _overflow.value, 0, velocity),
        ),
      );
    }
  }

  @override
  void dispose() {
    _overflow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The give is positional, so reduce-motion drops it
    // (see AppMotion.reduced).
    final reduced = AppMotion.reduced(context);
    return NotificationListener<SheetNotification>(
      onNotification: (notification) {
        switch (notification) {
          case SheetDragStartNotification():
            _dragging = true;
          // Cancel matters as much as end: a drag the gesture arena takes away
          // mid-pull would otherwise leave the sheet held off its detent.
          case SheetDragEndNotification(:final dragDetails):
            _dragging = false;
            // The give grows as the sheet is pushed *down* past its lowest
            // detent, so its rate is the finger's vertical velocity inverted.
            _cleanup(velocity: -dragDetails.velocityY);
          case SheetDragCancelNotification():
            _dragging = false;
            _cleanup();
          case SheetOverflowNotification(:final overflow, :final metrics):
            if (_dragging && _isFloor(metrics, overflow)) {
              _onFloorOverflow(overflow);
            } else {
              _cleanup();
            }
          default:
            break;
        }
        return false;
      },
      child: AnimatedBuilder(
        animation: _overflow,
        // Passed through untouched: the give is a transform, so the sheet's
        // content never rebuilds for it.
        child: widget.child,
        builder: (context, child) {
          final floorPx = reduced ? 0.0 : _rubberBand(_overflow.value);
          return Transform.translate(
            offset: Offset(0, floorPx),
            child: _SheetFloorScope(
              load: floorPx / _maxFloorGivePx,
              child: child!,
            ),
          );
        },
      ),
    );
  }
}

class _SheetFloorScope extends InheritedWidget {
  const _SheetFloorScope({required this.load, required super.child});

  final double load;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SheetFloorScope>()?.load ?? 0;

  @override
  bool updateShouldNotify(_SheetFloorScope oldWidget) => oldWidget.load != load;
}
