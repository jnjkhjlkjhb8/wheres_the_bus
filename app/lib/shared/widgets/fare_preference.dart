import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

class FarePreferenceBuilder extends StatelessWidget {
  const FarePreferenceBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, FareType fareType) builder;

  @override
  Widget build(BuildContext context) {
    if (!HiveStore.settingsReady) {
      return builder(context, FareType.full);
    }
    return ValueListenableBuilder(
      valueListenable: HiveStore.settings.listenable(
        keys: const [SettingsRepository.fareTypeKey],
      ),
      builder: (context, _, _) =>
          builder(context, SettingsRepository.instance.fareType),
    );
  }
}

class FareAmount extends StatelessWidget {
  const FareAmount({
    required this.fare,
    required this.requested,
    this.style,
    super.key,
  });

  final ResolvedFare fare;

  /// The rider's preference, to compare against `ResolvedFare.matched`.
  final FareType requested;

  /// Overrides the price style. Defaults to the screen-heading scale.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final isFallback = fare.matched != requested;
    final priceStyle = (style ?? AppTextStyles.heading1).copyWith(
      fontFeatures: AppTextStyles.tabularFigures,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            // Keyed on the value so a preference change cross-fades the number
            // instead of swapping it — the price is the one thing on screen
            // that changed, and a hard swap reads as a glitch.
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? AppMotion.instant
                  : AppMotion.micro,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.easeOut,
              child: Text(
                '\$${fare.price}',
                key: ValueKey(fare.price),
                style: priceStyle,
              ),
            ),
            const SizedBox(width: AppTheme.space8),
            Text(
              fare.matched.labelOf(i18n),
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (isFallback)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.space2),
            child: Text(
              i18n.fareFallbackNote(
                requested.labelOf(i18n),
                fare.matched.labelOf(i18n),
              ),
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
