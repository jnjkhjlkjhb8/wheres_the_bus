import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';

/// Compact inline notice for a live stream that never came up — deliberately
/// smaller than the full-page error card, since the page's static content is
/// still shown underneath it.
class LiveDataNotice extends StatelessWidget {
  const LiveDataNotice({
    required this.title,
    required this.body,
    required this.onReload,
    super.key,
  });

  final String title;
  final String body;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space12,
        AppTheme.space12,
        AppTheme.space12,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyRegular.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTheme.space2),
                Text(
                  body,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.space12),
          AppButton.outlined(
            label: AppI18n.of(context).commonReload,
            onPressed: onReload,
          ),
        ],
      ),
    );
  }
}
