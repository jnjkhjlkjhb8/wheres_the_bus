import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

/// Semantic variant of an [AppSnackbar]. Meaning is carried by a small leading
/// icon only; the surface stays ink so it reads calm (see design principle
/// "present uncertainty gracefully").
enum SnackType { neutral, success, error }

abstract final class AppSnackbar {
  /// On-dark error tint. The token red (#BA1A1A) is too dark to read on the
  /// ink surface, so the icon uses a lighter red at the same hue.
  static const Color _errorOnInk = Color(0xFFF97066);

  static void show(
    BuildContext context,
    String message, {
    SnackType type = SnackType.neutral,
    String? action,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    ScaffoldMessenger.of(context)
      // New toast replaces the current one instead of stacking behind it.
      ..clearSnackBars()
      ..showSnackBar(
        snackBarAnimationStyle: const AnimationStyle(
          duration: AppMotion.medium,
          // Leaving is the system responding, not the rider deciding, so the
          // exit is shorter than the entrance.
          reverseDuration: AppMotion.short,
        ),
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          dismissDirection: DismissDirection.down,
          // Actions get a longer dwell so undo stays reachable.
          duration: duration ?? Duration(seconds: action != null ? 4 : 2),
          content: _SnackContent(
            message: message,
            type: type,
            action: action,
            onAction: onAction,
          ),
        ),
      );
  }
}

class _SnackContent extends StatelessWidget {
  const _SnackContent({
    required this.message,
    required this.type,
    this.action,
    this.onAction,
  });

  final String message;
  final SnackType type;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bg = isLight ? AppTheme.inkLight : AppTheme.surfaceHighlightDark;
    final icon = switch (type) {
      SnackType.neutral => null,
      SnackType.success => (
        Icons.check_circle_outline_rounded,
        AppTheme.statusArriving,
      ),
      SnackType.error => (Icons.error_outline_rounded, AppSnackbar._errorOnInk),
    };

    return Center(
      child: _SnackTransition(
        child: Container(
          // 44 tall whatever the toast carries: the action's tap target is the
          // pill's own height, so an undo toast is the same pill as a plain
          // one. A wrapped message grows past it rather than clipping.
          constraints: const BoxConstraints(maxWidth: 440, minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.space16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            boxShadow: AppShadows.floating,
          ),
          // The row's own height drives the action's tap target, so the action
          // stretches to it instead of imposing a 44px floor of its own.
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (icon != null) ...[
                  Center(child: Icon(icon.$1, size: 20, color: icon.$2)),
                  const SizedBox(width: AppTheme.space12),
                ],
                Flexible(
                  // widthFactor 1 so the pill still hugs a short message; the
                  // unset heightFactor lets it centre in the stretched row.
                  child: Center(
                    widthFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppTheme.space12,
                      ),
                      child: Text(
                        message,
                        style: AppTextStyles.bodySmall.copyWith(
                          // inkDark reads on both the light-mode ink and
                          // dark-mode elevated surfaces.
                          color: AppTheme.inkDark,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
                if (action != null) ...[
                  const SizedBox(width: AppTheme.space12),
                  Pressable(
                    onTap: () {
                      onAction?.call();
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    },
                    semanticLabel: action,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 44),
                      child: Align(
                        child: Text(
                          action!,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SnackTransition extends StatelessWidget {
  const _SnackTransition({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // ponytail: the controller belongs to ScaffoldMessenger and is only
    // reachable through the SnackBar it built. Owning the toast outright is
    // the alternative, and that is a whole overlay stack.
    final animation = context
        .findAncestorWidgetOfExactType<SnackBar>()
        ?.animation;
    if (animation == null || AppMotion.reduced(context)) {
      return child;
    }
    return SlideTransition(
      position:
          Tween<Offset>(
            begin: const Offset(0, 0.5),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: const Interval(0.4, 1, curve: AppMotion.easeOut),
            ),
          ),
      child: child,
    );
  }
}
