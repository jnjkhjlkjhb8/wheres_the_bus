import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

/// Surface the segment sits on, which decides how the track and thumb are
/// drawn. The physics, gestures and label behaviour are identical.
enum AppSegmentStyle {
  /// Recessed groove holding a raised, lighter thumb. For controls that sit in
  /// content — sheets, forms, detail panes.
  groove,

  /// Floating card holding an inverted (dark) thumb. For controls that sit
  /// over the map, where a light thumb loses its edge against the imagery.
  floating,
}

class AppSlidingSegment<T> extends StatefulWidget {
  const AppSlidingSegment({
    required this.options,
    required this.value,
    required this.onChanged,
    this.muted = const {},
    this.style = AppSegmentStyle.groove,
    this.fill = true,
    super.key,
  }) : assert(options.length >= 2, 'At least two options are required.');

  final Map<T, String> options;
  final T value;

  /// Called on commit. The control fires the selection haptic itself, so call
  /// sites should not add their own.
  final ValueChanged<T> onChanged;

  /// Options whose label is dimmed because they carry nothing to show (a
  /// weekday the route does not run). They stay selectable — the dim state is
  /// a preview of the answer, not a lock.
  final Set<T> muted;

  final AppSegmentStyle style;

  /// Whether the control stretches to the width it is offered. When false it
  /// hugs its content instead — every segment as wide as the widest label —
  /// which is what a control floating over the map wants.
  final bool fill;

  @override
  State<AppSlidingSegment<T>> createState() => _AppSlidingSegmentState<T>();
}

class _AppSlidingSegmentState<T> extends State<AppSlidingSegment<T>>
    with TickerProviderStateMixin {
  /// How far past the end segments the thumb can be pulled, in segments. Small
  /// on purpose: this is a short control, and the resistance only has to say
  /// "there is nothing more here".
  static const double _overshoot = 0.12;

  static const double _flickProjection = 0.199;

  /// Release speed, in segments/second, above which the settle is allowed the
  /// slight overshoot of [AppMotion.springMomentum]. Below it the gesture
  /// carried no momentum to express.
  static const double _momentumThreshold = 0.5;

  late final AnimationController _thumb = AnimationController.unbounded(
    vsync: this,
    value: _indexOf(widget.value).toDouble(),
  );

  /// Thumb press-scale: 0 at rest, 1 while the thumb is held. Driven from
  /// pointer-down rather than from the commit, so the control answers the
  /// press before it answers the choice.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: AppMotion.press,
  );

  final GlobalKey _trackKey = GlobalKey();

  /// Pill width in logical pixels — converts a horizontal drag delta into
  /// thumb progress. Zero before the first layout.
  double get _pillStride {
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    return box.size.width / widget.options.length;
  }

  /// Unresisted drag position. [_thumb] holds its rubber-banded projection, so
  /// accumulating the raw deltas separately keeps the resistance from
  /// compounding frame over frame.
  double _dragRaw = 0;

  /// Whether the pointer went down on the thumb. Only then does a horizontal
  /// drag move anything.
  bool _grabbed = false;

  bool get _reduceMotion => AppMotion.reduced(context);

  int get _lastIndex => widget.options.length - 1;

  int _indexOf(T value) =>
      widget.options.keys.toList().indexOf(value).clamp(0, _lastIndex);

  @override
  void didUpdateWidget(AppSlidingSegment<T> old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _springTo(_indexOf(widget.value).toDouble(), _thumb.velocity);
    }
  }

  @override
  void dispose() {
    _thumb.dispose();
    _press.dispose();
    super.dispose();
  }

  void _springTo(double target, double velocity, {bool momentum = false}) {
    if (_reduceMotion) {
      _thumb.value = target;
      return;
    }
    unawaited(
      _thumb.animateWith(
        SpringSimulation(
          momentum ? AppMotion.springMomentum : AppMotion.spring,
          _thumb.value,
          target,
          velocity,
        ),
      ),
    );
  }

  /// Progressive resistance past the ends, asymptotically approaching
  /// [_overshoot]. A hard clamp reads as a frozen control; resistance reads as
  /// a responsive one that has run out of options.
  double _resist(double value) {
    final last = _lastIndex.toDouble();
    double band(double over) => over * _overshoot / (over + _overshoot);
    if (value < 0) return -band(-value);
    if (value > last) return last + band(value - last);
    return value;
  }

  void _pressThumb({required bool down}) {
    _press.duration = _reduceMotion ? AppMotion.instant : AppMotion.press;
    unawaited(down ? _press.forward() : _press.reverse());
  }

  void _commit(int index) {
    final keys = widget.options.keys.toList();
    if (keys[index] == widget.value) return;
    widget.onChanged(keys[index]);
  }

  void _handleTap(int index) {
    _commit(index);
    _springTo(index.toDouble(), 0);
  }

  void _handleDragDown(DragDownDetails details) {
    final stride = _pillStride;
    final left = _thumb.value.clamp(0.0, _lastIndex.toDouble()) * stride;
    _grabbed =
        stride > 0 &&
        details.localPosition.dx >= left &&
        details.localPosition.dx <= left + stride;
    if (_grabbed) _pressThumb(down: true);
  }

  void _handleDragCancel() {
    if (!_grabbed) return;
    _grabbed = false;
    _pressThumb(down: false);
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_grabbed) return;
    _thumb.stop();
    _dragRaw = _thumb.value;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final stride = _pillStride;
    if (!_grabbed || stride <= 0) return;
    _dragRaw += details.delta.dx / stride;
    _thumb.value = _resist(_dragRaw);
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_grabbed) return;
    _grabbed = false;
    _pressThumb(down: false);
    final stride = _pillStride;
    final velocity = stride > 0
        ? details.velocity.pixelsPerSecond.dx / stride
        : 0.0;
    // Land where the flick was going, not where the finger stopped, then snap
    // to the segment nearest that projected point.
    final target = (_thumb.value + velocity * _flickProjection).round().clamp(
      0,
      _lastIndex,
    );
    _commit(target);
    _springTo(
      target.toDouble(),
      velocity,
      momentum: velocity.abs() > _momentumThreshold,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = widget.options.entries.toList();
    final skin = _SegmentSkin.of(widget.style, cs);

    final track = GestureDetector(
      onHorizontalDragDown: _handleDragDown,
      onHorizontalDragCancel: _handleDragCancel,
      onHorizontalDragStart: _handleDragStart,
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: SizedBox(
        key: _trackKey,
        height: 36,
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: Listenable.merge([_thumb, _press]),
                builder: (context, child) => Align(
                  // Alignment.x runs -1..1 across the *free* space, which is
                  // the track minus one pill: at progress p of `_lastIndex`
                  // segments the thumb's left edge must sit at p pills in.
                  alignment: Alignment(2 * _thumb.value / _lastIndex - 1, 0),
                  child: FractionallySizedBox(
                    widthFactor: 1 / entries.length,
                    heightFactor: 1,
                    child: Transform.scale(
                      scale: 1 - (1 - AppMotion.pressedScale) * _press.value,
                      child: child,
                    ),
                  ),
                ),
                child: Container(decoration: skin.thumb),
              ),
            ),
            Row(
              children: entries.asMap().entries.map((indexed) {
                final index = indexed.key;
                final entry = indexed.value;
                final muted = widget.muted.contains(entry.key);
                return Expanded(
                  child: Semantics(
                    button: true,
                    selected: entry.key == widget.value,
                    // Dimming is invisible to assistive tech, so the muted
                    // state is stated in the label instead.
                    label: muted
                        ? AppI18n.of(context).segmentNoService(entry.value)
                        : null,
                    child: Pressable(
                      onTap: () => _handleTap(index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.space10,
                        ),
                        child: Center(
                          child: _SegmentLabel(
                            text: entry.value,
                            index: index,
                            thumb: _thumb,
                            skin: skin,
                            muted: muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(AppTheme.space4),
      decoration: skin.track,
      // IntrinsicWidth over a row of equal flex children resolves to the
      // widest label times the option count, so hugging still yields equal
      // pills — the thumb's fractional width stays honest.
      child: widget.fill ? track : IntrinsicWidth(child: track),
    );
  }
}

class AppStaticSegment extends StatelessWidget {
  const AppStaticSegment({
    required this.label,
    this.leading,
    this.semanticLabel,
    this.style = AppSegmentStyle.groove,
    super.key,
  });

  final String label;

  /// Glyph placed before the label, sized and coloured by the control so it
  /// reads as part of the same vocabulary wherever it is used.
  final IconData? leading;

  /// What assistive tech announces. The visual pill states "one direction"
  /// only through its shape, which is invisible to a screen reader.
  final String? semanticLabel;

  final AppSegmentStyle style;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Only the track is borrowed from the skin. The label sits on the track
    // rather than on a thumb, so it takes plain ink in both styles — the
    // floating skin's inverted label colour would vanish here.
    final skin = _SegmentSkin.of(style, cs);
    return Semantics(
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(AppTheme.space4),
        decoration: skin.track,
        child: SizedBox(
          height: 36,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leading != null) ...[
                Icon(leading, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: AppTheme.space6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyRegular.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Label whose weight and colour follow the thumb's live position rather than
/// the committed value, so a segment lights up as the thumb is dragged across
/// it instead of snapping at release.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    required this.text,
    required this.index,
    required this.thumb,
    required this.skin,
    required this.muted,
  });

  final String text;
  final int index;
  final Animation<double> thumb;
  final _SegmentSkin skin;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: thumb,
      builder: (context, _) {
        final covered = (1 - (thumb.value - index).abs()).clamp(0.0, 1.0);
        return Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyRegular.copyWith(
            fontWeight: FontWeight.lerp(
              FontWeight.w400,
              FontWeight.w600,
              covered,
            ),
            color: Color.lerp(
              skin.label.withValues(alpha: muted ? .4 : 1),
              skin.labelSelected,
              covered,
            ),
          ),
        );
      },
    );
  }
}

/// The two surface treatments, resolved once per build.
class _SegmentSkin {
  const _SegmentSkin({
    required this.track,
    required this.thumb,
    required this.label,
    required this.labelSelected,
  });

  factory _SegmentSkin.of(AppSegmentStyle style, ColorScheme cs) {
    final isDark = cs.brightness == Brightness.dark;
    if (style == AppSegmentStyle.floating) {
      const radius = BorderRadius.all(
        Radius.circular(AppTheme.radiusStadium),
      );
      return _SegmentSkin(
        track: AppTheme.floatingControl(cs, borderRadius: radius),
        thumb: BoxDecoration(color: cs.onSurface, borderRadius: radius),
        label: cs.onSurfaceVariant,
        // Inverted against the dark thumb: this control floats over the map,
        // where a light thumb would lose its edge against the imagery.
        labelSelected: cs.surface,
      );
    }
    return _SegmentSkin(
      track: BoxDecoration(
        color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      thumb: BoxDecoration(
        color: isDark ? cs.surfaceContainerHighest : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(7),
        // Light: a hairline defines the white thumb when it sits on an equally
        // white sheet. Dark needs no edge — the lighter thumb already
        // separates from the groove.
        border: isDark
            ? null
            : Border.all(
                color: Colors.black.withValues(alpha: .04),
                width: .5,
              ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .25 : .05),
            blurRadius: isDark ? 2 : 4,
            offset: Offset(0, isDark ? 1 : 2),
          ),
        ],
      ),
      label: cs.onSurfaceVariant,
      labelSelected: cs.onSurface,
    );
  }

  final BoxDecoration track;
  final BoxDecoration thumb;
  final Color label;
  final Color labelSelected;
}
