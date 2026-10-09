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

    final noBikes = hasLiveData && available == 0;
    final noDocks = hasLiveData && docks == 0;
    final lowBikes = hasLiveData && !noBikes && available <= _lowLimit(total);

    final ({String text, Color color})? flag;
    if (!hasLiveData) {
      flag = (
        text: AppI18n.of(context).bikeWaitingLive,
        color: cs.onSurfaceVariant,
      );
    } else if (noBikes && noDocks) {
      // Physically impossible while the station is in service: every dock is
      // either holding a bike or free to take one.
      flag = (
        text: AppI18n.of(context).bikeSuspended,
        color: AppTheme.etaArriving,
      );
    } else if (noBikes) {
      flag = (
        text: AppI18n.of(context).bikeNoBikes,
        color: AppTheme.etaArriving,
      );
    } else if (noDocks) {
      flag = (
        text: AppI18n.of(context).bikeNoDocks,
        color: AppTheme.etaArriving,
      );
    } else if (lowBikes) {
      flag = (
        text: AppI18n.of(context).bikeFewBikes,
        color: AppTheme.etaApproaching,
      );
    } else {
      flag = null;
    }

    final borrowColor = noBikes
        ? AppTheme.etaArriving
        : lowBikes
        ? AppTheme.etaApproaching
        : cs.onSurface;
    final returnColor = noDocks ? AppTheme.etaArriving : cs.onSurface;

    return Semantics(
      container: true,
      label: hasLiveData
          ? '${AppI18n.of(context).bikeGaugeSemantics(total, available, docks)}'
                '${flag == null ? '' : '，${flag.text}'}'
          : AppI18n.of(context).bikeGaugeNoLiveSemantics(total),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DockRack(
            filled: hasLiveData ? available : 0,
            total: total,
          ),
          const SizedBox(height: AppTheme.space10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _EndCount(
                  value: hasLiveData ? '$available' : '—',
                  unit: AppI18n.of(context).bikeUnitBikes,
                  caption: _borrowCaption(AppI18n.of(context)),
                  color: hasLiveData ? borrowColor : cs.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: _EndCount(
                  value: hasLiveData ? '$docks' : '—',
                  unit: AppI18n.of(context).bikeUnitDocks,
                  caption: AppI18n.of(context).bikeReturnSpaces,
                  color: hasLiveData ? returnColor : cs.onSurfaceVariant,
                  alignEnd: true,
                ),
              ),
            ],
          ),
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

  /// `可借` alone, or with the by-type split appended. The split used to be
  /// two full rows restating a sum already shown above them.
  String _borrowCaption(AppI18n i18n) {
    if (!hasLiveData) return i18n.bikeAvailable;
    final general = generalBikes;
    final electric = electricBikes;
    if (general == null && electric == null) return i18n.bikeAvailable;
    final parts = <String>[
      if (general != null && general > 0) i18n.bikeGeneralCount(general),
      if (electric != null && electric > 0) i18n.bikeElectricCount(electric),
    ];
    if (parts.isEmpty) return i18n.bikeAvailable;
    return '${i18n.bikeAvailable} · ${parts.join(' · ')}';
  }
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
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: fraction),
          duration: AppMotion.reduced(context)
              ? AppMotion.instant
              : AppMotion.medium,
          curve: AppMotion.easeInOut,
          builder: (context, value, _) => RepaintBoundary(
            child: CustomPaint(
              size: Size(width, _height),
              painter: _RackPainter(
                slots: slots,
                fraction: value,
                gap: slots == 1 ? 0 : _gap,
                radius: slots == 1
                    ? AppTheme.radiusStadium
                    : AppTheme.radiusSlot,
                emptyColor: cs.outlineVariant,
                filledColor: AppTheme.statusArriving,
              ),
            ),
          ),
        );
      },
    );
  }
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
    for (final r in rects) {
      canvas.drawRRect(r, empty);
    }

    if (fraction <= 0) return;
    // The green layer is the same rack clipped to the fill boundary, which is
    // what lets a boundary mid-slot render as a partly-filled bay while the
    // count animates across it.
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, size.width * fraction, size.height));
    final full = Paint()..color = filledColor;
    for (final r in rects) {
      canvas.drawRRect(r, full);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RackPainter old) =>
      old.slots != slots ||
      old.fraction != fraction ||
      old.gap != gap ||
      old.radius != radius ||
      old.emptyColor != emptyColor ||
      old.filledColor != filledColor;
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
