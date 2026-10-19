import 'package:flutter/material.dart';

import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class FreshnessStamp extends StatelessWidget {
  const FreshnessStamp({required this.at, this.leading, super.key});

  /// When the data landed. Null renders nothing — a screen that has never
  /// received a frame has no freshness to state, and an empty stamp would
  /// read as "updated at nothing".
  final DateTime? at;

  /// Rendered before the stamp, separated by a middot. For a row that already
  /// carries a fact of the same weight (a dock count, a platform).
  final String? leading;

  @override
  Widget build(BuildContext context) {
    final time = at;
    final prefix = leading;
    if (time == null) {
      return prefix == null
          ? const SizedBox.shrink()
          : Text(prefix, style: _labelStyle(context));
    }

    final label = _labelStyle(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (prefix != null) Text('$prefix · ', style: label),
        Text('${AppI18n.of(context).commonUpdatedAt} ', style: label),
        // Mono-for-time: the reading is a figure, so it leaves the body face
        // even though the words before it do not.
        Text(
          hhmm(time),
          style: AppTextStyles.timeValue(
            size: 12,
          ).copyWith(color: label.color),
        ),
      ],
    );
  }

  TextStyle _labelStyle(BuildContext context) => AppTextStyles.bodySmall
      .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

  /// Zero-padded wall clock. Public so callers that render the reading inside
  /// their own layout still format it identically.
  static String hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
