import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class ComingSoonStopBanner extends StatelessWidget {
  const ComingSoonStopBanner({
    required this.name,
    this.time,
    this.label,
    super.key,
  });

  final String name;
  final String? time;

  /// Null takes the standard wording, which can only be resolved against a
  /// locale — and this constructor has no context to resolve it with.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space8,
        AppTheme.space16,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space12,
      ),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      child: Row(
        children: [
          Text(
            label ?? AppI18n.of(context).etaArrivingSoon,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppTheme.space8),
          Expanded(
            child: Text(
              name,
              style: AppTextStyles.heading2.copyWith(
                color: cs.onPrimaryContainer,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (time != null)
            Text(
              time!,
              style: AppTextStyles.timeValue(color: cs.onPrimaryContainer),
            ),
        ],
      ),
    );
  }
}
