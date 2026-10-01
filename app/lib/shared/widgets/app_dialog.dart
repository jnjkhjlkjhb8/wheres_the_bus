import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

Future<T?> showAppModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = '',
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: AppMotion.sheet,
    pageBuilder: (context, _, _) => Builder(builder: builder),
    transitionBuilder: (context, animation, _, child) {
      if (AppMotion.reduced(context)) {
        return child;
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.easeOut,
        reverseCurve: AppMotion.easeOut.flipped,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    super.key,
    this.content,
    this.body,
    this.actions,
  });

  final String title;
  final String? content;

  /// Arbitrary content below the title, for dialogs that need more than a
  /// text message (form fields, pickers). Rendered after [content] if both
  /// are supplied.
  final Widget? body;
  final List<Widget>? actions;

  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    String? content,
    Widget? body,
    List<Widget>? actions,
  }) {
    return showAppModal<T>(
      context: context,
      barrierLabel: title,
      builder: (_) => AppDialog(
        title: title,
        content: content,
        body: body,
        actions: actions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      // Elevated surface, not the scaffold's own colour: `surface` leaves the
      // dialog indistinguishable from the page behind it in dark mode.
      backgroundColor: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusModal),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppTextStyles.heading2.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (content != null) ...[
              const SizedBox(height: AppTheme.space8),
              Text(
                content!,
                style: AppTextStyles.bodyRegular.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
            if (body != null) ...[
              const SizedBox(height: AppTheme.space16),
              body!,
            ],
            if (actions != null) ...[
              const SizedBox(height: AppTheme.space24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions!
                    .map(
                      (a) => Padding(
                        padding: const EdgeInsets.only(left: AppTheme.space8),
                        child: a,
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
