import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class AlightPickCapsule extends StatelessWidget {
  const AlightPickCapsule({required this.onCancel, super.key});

  /// Leaves pick-mode with nothing started.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.only(
        left: AppTheme.space16,
        right: AppTheme.space4,
      ),
      decoration: BoxDecoration(
        color: cs.onSurface,
        borderRadius: BorderRadius.circular(AppTheme.radiusStadium),
        boxShadow: AppShadows.floating,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            i18n.alightPickTitle,
            style: AppTextStyles.bodyRegular.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.surface,
            ),
          ),
          const SizedBox(width: AppTheme.space4),
          Pressable(
            onTap: () {
              // Leaving a mode is a commit of its own, and the rider gets no
              // other feedback for it.
              unawaited(HapticService.instance.lightTap());
              onCancel();
            },
            semanticLabel: i18n.commonClose,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                Icons.close_rounded,
                size: 18,
                // Just under the label: the way out has to be findable without
                // competing with the sentence that explains the mode.
                color: cs.surface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AlightPickCapsuleHost extends StatelessWidget {
  const AlightPickCapsuleHost({
    required this.picking,
    required this.onCancel,
    required this.child,
    this.topInset = 14,
    super.key,
  });

  final bool picking;
  final VoidCallback onCancel;
  final Widget child;

  /// Distance from the top of the host to the capsule. Screens with their own
  /// chrome (an app bar, a sheet handle) push it clear of that.
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        child,
        Positioned(
          top: topInset,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !picking,
            child: AnimatedOpacity(
              opacity: picking ? 1 : 0,
              duration: reduced ? AppMotion.instant : AppMotion.short,
              curve: AppMotion.easeOut,
              child: Center(child: AlightPickCapsule(onCancel: onCancel)),
            ),
          ),
        ),
      ],
    );
  }
}
