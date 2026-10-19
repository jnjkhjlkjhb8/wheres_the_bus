import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

enum TrainType {
  newTzeChiang,
  localExpress,
  local,
  puyuma,
  taroko,
  tzeChiang,
  chuKuang,
  thsr,
  other;

  static TrainType of(String type) {
    final t = type.trim();
    const aliases = {
      'EMU3000': TrainType.newTzeChiang,
      '3000': TrainType.newTzeChiang,
      '新自強': TrainType.newTzeChiang,
      '區間快': TrainType.localExpress,
      '區間': TrainType.local,
      '普悠瑪': TrainType.puyuma,
      '太魯閣': TrainType.taroko,
      '自強': TrainType.tzeChiang,
      '莒光': TrainType.chuKuang,
      '高鐵': TrainType.thsr,
    };
    for (final entry in aliases.entries) {
      if (t.contains(entry.key)) return entry.value;
    }
    return TrainType.other;
  }

  /// The canonical display name. [raw] is echoed back for [other], which is
  /// whatever the backend called a class the app has no chip for.
  String labelOf(AppI18n i18n, String raw) => switch (this) {
    TrainType.newTzeChiang => i18n.trainTypeNewTzeChiang,
    TrainType.localExpress => i18n.trainTypeLocalExpress,
    TrainType.local => i18n.trainTypeLocal,
    TrainType.puyuma => i18n.trainTypePuyuma,
    TrainType.taroko => i18n.trainTypeTaroko,
    TrainType.tzeChiang => i18n.trainTypeTzeChiang,
    TrainType.chuKuang => i18n.trainTypeChuKuang,
    TrainType.thsr => i18n.modeThsr,
    TrainType.other => raw.trim(),
  };

  /// The chip label for a dense row, which drops the 車/號 suffix the full
  /// name carries: the stem is what tells the classes apart, and the suffix is
  /// what pushes the chip wide enough to squeeze the columns beside it.
  String compactLabelOf(AppI18n i18n, String raw) => switch (this) {
    TrainType.newTzeChiang => i18n.trainTypeNewTzeChiangShort,
    TrainType.localExpress => i18n.trainTypeLocalExpressShort,
    TrainType.local => i18n.trainTypeLocalShort,
    TrainType.tzeChiang => i18n.trainTypeTzeChiangShort,
    TrainType.chuKuang => i18n.trainTypeChuKuangShort,
    _ => labelOf(i18n, raw),
  };

  Color get color => switch (this) {
    TrainType.newTzeChiang => AppTheme.train3000,
    TrainType.localExpress => AppTheme.trainRangefast,
    TrainType.local => AppTheme.trainRangecar,
    TrainType.puyuma => AppTheme.trainDelay,
    TrainType.taroko => AppTheme.trainTaroko,
    TrainType.tzeChiang => AppTheme.trainSelfstrong,
    TrainType.chuKuang => AppTheme.trainOrangelight,
    TrainType.thsr => AppTheme.trainThsr,
    TrainType.other => Colors.grey,
  };
}

/// Color-coded chip for a train type label.
class TrainTypeChip extends StatelessWidget {
  const TrainTypeChip({required this.type, super.key, this.compact = false});

  /// Backend train type label to display.
  final String type;

  /// Drops the chip to the shortened label and a smaller box, for dense rows
  /// where the full name would squeeze the columns beside it.
  final bool compact;

  static String canonicalLabel(AppI18n i18n, String type) =>
      TrainType.of(type).labelOf(i18n, type);

  /// WCAG contrast ratio between two colours, always at least 1.
  @visibleForTesting
  static double contrastRatio(Color a, Color b) {
    final ratio = (a.computeLuminance() + 0.05) / (b.computeLuminance() + 0.05);
    return ratio < 1 ? 1 / ratio : ratio;
  }

  /// The more legible of [dark] and [light] on [background]; [dark] wins a tie.
  @visibleForTesting
  static Color labelColorFor(
    Color background, {
    Color dark = AppTheme.inkLight,
    Color light = Colors.white,
  }) => contrastRatio(background, dark) >= contrastRatio(background, light)
      ? dark
      : light;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final trainType = TrainType.of(type);
    final color = trainType.color;
    final labelColor = labelColorFor(color);
    return Container(
      height: compact ? null : 28,
      constraints: compact
          ? BoxConstraints(
              minWidth: MediaQuery.textScalerOf(context).scale(46),
            )
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: _horizontalPadding,
        vertical: _verticalPadding,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.25,
        ),
      ),
      child: _label(i18n, trainType, labelColor),
    );
  }

  double get _horizontalPadding => compact ? AppTheme.space6 : AppTheme.space12;
  double get _verticalPadding => compact ? AppTheme.space2 : 0;

  Widget _label(AppI18n i18n, TrainType trainType, Color labelColor) {
    return Text(
      compact
          ? trainType.compactLabelOf(i18n, type)
          : trainType.labelOf(i18n, type),
      style: (compact ? AppTextStyles.bodyVerySmall : AppTextStyles.bodySmall)
          .copyWith(
            color: labelColor,
            fontWeight: FontWeight.w600,
            height: compact ? 1.2 : null,
          ),
      textAlign: TextAlign.center,
    );
  }
}
