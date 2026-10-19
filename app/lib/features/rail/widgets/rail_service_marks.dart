import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/core/assets/remote_image.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

enum RailServiceMark {
  wheelchair('rails/notes/serve-wheelchair.png'),
  bike('rails/notes/serve-bicy.png'),
  dining('rails/notes/serve-lunchbox.png'),
  breastfeeding('rails/notes/serve-nursingroom.png'),
  daily('rails/notes/serve-everyday.png'),
  overnight('rails/notes/serve-crossday.png');

  const RailServiceMark(this.asset);

  final String asset;

  String labelOf(AppI18n i18n) => switch (this) {
    RailServiceMark.wheelchair => i18n.railServiceWheelchair,
    RailServiceMark.bike => i18n.railServiceBike,
    RailServiceMark.dining => i18n.railServiceDining,
    RailServiceMark.breastfeeding => i18n.railServiceNursing,
    RailServiceMark.daily => i18n.railServiceDaily,
    RailServiceMark.overnight => i18n.railServiceOvernight,
  };

  static const Set<RailServiceMark> _listVisible = {
    wheelchair,
    bike,
    dining,
    breastfeeding,
    overnight,
  };

  bool get showsInList => _listVisible.contains(this);

  static List<RailServiceMark> forTra(TraTimetableItem item) => [
    if (item.isDisabledFriendly) wheelchair,
    if (item.hasBike) bike,
    if (item.hasDiningCar) dining,
    if (item.hasBreastfeeding) breastfeeding,
    if (item.runsDaily) daily,
  ];

  static List<RailServiceMark> forThsr(ThsrTimetableItem item) => [
    if (item.isOvernight) overnight,
  ];
}

class RailServiceMarkRow extends StatelessWidget {
  const RailServiceMarkRow({
    required this.marks,
    super.key,
    this.maxVisible = 3,
  });

  final List<RailServiceMark> marks;

  /// Marks past this count collapse into a `+N` counter rather than squeezing
  /// the train number column.
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = marks.where((m) => m.showsInList).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final shown = visible.take(maxVisible).toList();
    final overflow = visible.length - shown.length;

    return Semantics(
      label: visible.map((m) => m.labelOf(AppI18n.of(context))).join('、'),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mark in shown) ...[
            RemoteImage(mark.asset, size: 14),
            const SizedBox(width: 3),
          ],
          if (overflow > 0)
            Text(
              '+$overflow',
              style: AppTextStyles.memo.copyWith(
                fontSize: 10,
                color: cs.outline,
              ),
            ),
        ],
      ),
    );
  }
}

/// The marks as they appear on the train detail screen: original artwork with
/// its label, wrapped so long lists reflow instead of clipping.
class RailServiceMarkChips extends StatelessWidget {
  const RailServiceMarkChips({required this.marks, super.key});

  final List<RailServiceMark> marks;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      children: [
        for (final mark in marks)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RemoteImage(mark.asset, size: 20),
            ],
          ),
      ],
    );
  }
}
