import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

class AvailabilityGauge extends StatelessWidget {
  const AvailabilityGauge({
    required this.available,
    required this.docks,
    super.key,
    this.capacity = 0,
    this.generalBikes,
    this.electricBikes,
    this.hasLiveData = true,
  });

  final int available;
  final int docks;

  /// Total dock slots at the station. 0 = unknown.
  final int capacity;

  /// Breakdown of [available] by bike type. Both null omits the breakdown
  /// line; it is a detail of the borrow count, not a list of its own.
  final int? generalBikes;
  final int? electricBikes;

  final bool hasLiveData;

  /// Floor for the "running low" warning, so a tiny station is not permanently
  /// flagged. Above it the threshold scales with the station (see [_lowLimit]).
  static const _lowFloor = 2;

  /// Total slots the rack draws.
  int get _total {
    final t = capacity > 0 ? capacity : available + docks;
    return t < 1 ? 1 : t;
  }

  /// "Running low" is relative: 3 bikes left at a 60-dock hub is nearly empty,
  /// 3 left at a 4-dock station is most of it. The old fixed `<= 2` called
  /// both the same thing.
  static int _lowLimit(int total) {
    final tenth = (total * 0.1).round();
    return tenth > _lowFloor ? tenth : _lowFloor;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = _total;

    final noBikes = _noBikes;
    final noDocks = _noDocks;
    final lowBikes = _lowBikes;

    final flag = _statusFlag(
      AppI18n.of(context),
      cs,
      noBikes,
      noDocks,
      lowBikes,
    );

    return Semantics(
      container: true,
      label: _semanticsLabel(AppI18n.of(context), total, flag?.text),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DockRack(
            filled: hasLiveData ? available : 0,
            total: total,
          ),
          const SizedBox(height: AppTheme.space10),
          _counts(context, noBikes, noDocks, lowBikes),
          if (flag != null) ...[
            const SizedBox(height: AppTheme.space14),
            Text(
              flag.text,
              style: AppTextStyles.bodySmall.copyWith(
                color: flag.color,
                fontWeight: hasLiveData ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool get _noBikes => hasLiveData && available == 0;
  bool get _noDocks => hasLiveData && docks == 0;
  bool get _lowBikes =>
      hasLiveData && !_noBikes && available <= _lowLimit(_total);

  String _semanticsLabel(AppI18n i18n, int total, String? flag) {
    if (!hasLiveData) return i18n.bikeGaugeNoLiveSemantics(total);
    final counts = i18n.bikeGaugeSemantics(total, available, docks);
    return flag == null ? counts : '$counts，$flag';
  }

  ({String text, Color color})? _statusFlag(
    AppI18n i18n,
    ColorScheme colors,
    bool noBikes,
    bool noDocks,
    bool lowBikes,
  ) {
    if (!hasLiveData) {
      return (text: i18n.bikeWaitingLive, color: colors.onSurfaceVariant);
    }
    return _liveStatusFlag(i18n, noBikes, noDocks, lowBikes);
  }

  ({String text, Color color})? _liveStatusFlag(
    AppI18n i18n,
    bool noBikes,
    bool noDocks,
    bool lowBikes,
  ) {
    if (noBikes) return _noBikeFlag(i18n, noDocks);
    if (noDocks) return (text: i18n.bikeNoDocks, color: AppTheme.etaArriving);
    if (lowBikes) {
      return (text: i18n.bikeFewBikes, color: AppTheme.etaApproaching);
    }
    return null;
  }

  ({String text, Color color}) _noBikeFlag(AppI18n i18n, bool noDocks) => (
    // Both zero means the station cannot currently serve a rider.
    text: noDocks ? i18n.bikeSuspended : i18n.bikeNoBikes,
    color: AppTheme.etaArriving,
  );

  Widget _counts(
    BuildContext context,
    bool noBikes,
    bool noDocks,
    bool lowBikes,
  ) {
    final colors = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _borrowCount(i18n, colors, noBikes, lowBikes)),
        Expanded(child: _returnCount(i18n, colors, noDocks)),
      ],
    );
  }

  Color _borrowColor(ColorScheme colors, bool noBikes, bool lowBikes) {
    if (!hasLiveData) return colors.onSurfaceVariant;
    return noBikes
        ? AppTheme.etaArriving
        : lowBikes
        ? AppTheme.etaApproaching
        : colors.onSurface;
  }

  Widget _borrowCount(
    AppI18n i18n,
    ColorScheme colors,
    bool noBikes,
    bool lowBikes,
  ) => _EndCount(
    value: hasLiveData ? '$available' : '—',
    unit: i18n.bikeUnitBikes,
    caption: _borrowCaption(i18n),
    color: _borrowColor(colors, noBikes, lowBikes),
  );

  Widget _returnCount(AppI18n i18n, ColorScheme colors, bool noDocks) =>
      _EndCount(
        value: hasLiveData ? '$docks' : '—',
        unit: i18n.bikeUnitDocks,
        caption: i18n.bikeReturnSpaces,
        color: !hasLiveData
            ? colors.onSurfaceVariant
            : noDocks
            ? AppTheme.etaArriving
            : colors.onSurface,
        alignEnd: true,
      );

  /// `可借` alone, or with the by-type split appended. The split used to be
  /// two full rows restating a sum already shown above them.
  String _borrowCaption(AppI18n i18n) {
    if (!hasLiveData) return i18n.bikeAvailable;
    final general = generalBikes;
    final electric = electricBikes;
    final parts = <String>[
      ..._bikeCountCaption(general, i18n.bikeGeneralCount),
      ..._bikeCountCaption(electric, i18n.bikeElectricCount),
    ];
    if (parts.isEmpty) return i18n.bikeAvailable;
    return '${i18n.bikeAvailable} · ${parts.join(' · ')}';
  }

  List<String> _bikeCountCaption(int? count, String Function(int) label) =>
      count != null && count > 0 ? [label(count)] : [];
}

class _DockRack extends StatelessWidget {
  const _DockRack({required this.filled, required this.total});

  final int filled;
  final int total;

  static const _height = 22.0;
  static const _gap = 2.0;

  /// Narrower than this and a slot stops reading as a bay and starts reading
  /// as dither, so the rack collapses into one continuous stadium bar.
  static const _minSlotWidth = 4.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fraction = total == 0 ? 0.0 : (filled / total).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slots = (width - (total - 1) * _gap) / total >= _minSlotWidth
            ? total
            : 1;
        return _animateRack(context, cs, width, slots, fraction);
      },
    );
  }

  Widget _animateRack(
    BuildContext context,
    ColorScheme colors,
    double width,
    int slots,
    double fraction,
  ) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: fraction),
    duration: AppMotion.reduced(context) ? AppMotion.instant : AppMotion.medium,
    curve: AppMotion.easeInOut,
    builder: (context, value, _) => _rackFrame(colors, width, slots, value),
  );

  Widget _rackFrame(
    ColorScheme colors,
    double width,
    int slots,
    double fraction,
  ) => RepaintBoundary(
    child: CustomPaint(
      size: Size(width, _height),
      painter: _RackPainter(
        slots: slots,
        fraction: fraction,
        gap: slots == 1 ? 0 : _gap,
        radius: slots == 1 ? AppTheme.radiusStadium : AppTheme.radiusSlot,
        emptyColor: colors.outlineVariant,
        filledColor: AppTheme.statusArriving,
      ),
    ),
  );
}

class _RackPainter extends CustomPainter {
  const _RackPainter({
    required this.slots,
    required this.fraction,
    required this.gap,
    required this.radius,
    required this.emptyColor,
    required this.filledColor,
  });

  final int slots;
  final double fraction;
  final double gap;
  final double radius;
  final Color emptyColor;
  final Color filledColor;

  @override
  void paint(Canvas canvas, Size size) {
    final advance = (size.width + gap) / slots;
    final slotWidth = advance - gap;
    final rects = <RRect>[
      for (var i = 0; i < slots; i++)
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * advance, 0, slotWidth, size.height),
          Radius.circular(radius),
        ),
    ];

    final empty = Paint()..color = emptyColor;
    _drawSlots(canvas, rects, empty);

    if (fraction <= 0) return;
    // The green layer is the same rack clipped to the fill boundary, which is
    // what lets a boundary mid-slot render as a partly-filled bay while the
    // count animates across it.
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, size.width * fraction, size.height));
    final full = Paint()..color = filledColor;
    _drawSlots(canvas, rects, full);
    canvas.restore();
  }

  void _drawSlots(Canvas canvas, List<RRect> rects, Paint paint) {
    for (final rect in rects) {
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_RackPainter old) => old._appearance != _appearance;

  (int, double, double, double, Color, Color) get _appearance =>
      (slots, fraction, gap, radius, emptyColor, filledColor);
}

/// One end label of the rack: the count, its unit, and what it counts.
class _EndCount extends StatelessWidget {
  const _EndCount({
    required this.value,
    required this.unit,
    required this.caption,
    required this.color,
    this.alignEnd = false,
  });

  final String value;
  final String unit;
  final String caption;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: AppTextStyles.timeValue(
                  size: 28,
                  height: 1.15,
                  weight: FontWeight.w600,
                  color: color,
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: AppTextStyles.bodySmall.copyWith(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          caption,
          style: AppTextStyles.bodySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
