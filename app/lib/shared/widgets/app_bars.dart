import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

/// Geometry every app bar shares. Screens compose different rows, but the tap
/// target, glyph size, slot gap and edge insets are identical so the back
/// button lands under the same thumb position on every screen.
abstract final class AppBarMetrics {
  static const double tapTarget = 44;
  static const double control = 40;
  static const double icon = 20;
  static const double gap = 12;
  static const double barHeight = 56;

  static const double floatingTop = AppTheme.space16;

  static const EdgeInsets floatingInsets = EdgeInsets.fromLTRB(
    AppTheme.space16,
    floatingTop,
    AppTheme.space16,
    AppTheme.space8,
  );
}

class AppBarCircleButton extends StatelessWidget {
  const AppBarCircleButton({
    required this.child,
    this.onTap,
    this.semanticLabel,
    super.key,
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: SizedBox(
        width: AppBarMetrics.tapTarget,
        height: AppBarMetrics.tapTarget,
        child: Center(
          child: Container(
            width: AppBarMetrics.control,
            height: AppBarMetrics.control,
            decoration: AppTheme.floatingControl(cs, shape: BoxShape.circle),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// The single back affordance. `floating` puts it on the circular chrome used
/// over maps; without it the glyph sits bare on an opaque bar. Same icon, size
/// and tap target either way — only the backing plate differs.
class AppBarBackButton extends StatelessWidget {
  const AppBarBackButton({this.onTap, this.floating = false, super.key});
  final VoidCallback? onTap;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = Icon(
      Icons.arrow_back_ios_new_rounded,
      size: AppBarMetrics.icon,
      color: cs.onSurface,
    );
    final label = AppI18n.of(context).commonBack;
    final tap = onTap ?? () => context.pop();

    if (floating) {
      return AppBarCircleButton(
        onTap: tap,
        semanticLabel: label,
        child: icon,
      );
    }
    return Pressable(
      onTap: tap,
      semanticLabel: label,
      child: SizedBox(
        width: AppBarMetrics.tapTarget,
        height: AppBarMetrics.tapTarget,
        child: Center(child: icon),
      ),
    );
  }
}

class FloatingAppBar extends StatelessWidget {
  const FloatingAppBar({
    this.leading,
    this.middle,
    this.trailing,
    this.automaticallyImplyLeading = true,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    super.key,
  });

  /// Defaults to the shared back button — see [automaticallyImplyLeading].
  final Widget? leading;
  final Widget? middle;
  final Widget? trailing;

  final bool automaticallyImplyLeading;

  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final start =
        leading ??
        (automaticallyImplyLeading
            ? const AppBarBackButton(floating: true)
            : null);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: AppBarMetrics.floatingInsets,
        child: middle == null
            ? Row(
                crossAxisAlignment: crossAxisAlignment,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [?start, ?trailing],
              )
            : Row(
                crossAxisAlignment: crossAxisAlignment,
                children: [
                  if (start != null) ...[
                    start,
                    const SizedBox(width: AppBarMetrics.gap),
                  ],
                  Expanded(child: middle!),
                  if (trailing != null) ...[
                    const SizedBox(width: AppBarMetrics.gap),
                    trailing!,
                  ],
                ],
              ),
      ),
    );
  }
}

/// The [FloatingAppBar] title slot: the same type ramp as [DetailAppBar] on
/// the floating plate, so a screen reads the same whether its header sits on
/// an opaque bar or over a map.
class AppBarTitlePill extends StatelessWidget {
  const AppBarTitlePill({required this.title, this.subtitle, super.key});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: AppBarMetrics.tapTarget),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space14,
        vertical: AppTheme.space6,
      ),
      decoration: AppTheme.floatingControl(
        cs,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _Title(title, subtitle),
      ),
    );
  }
}

/// Chrome for screens whose content is laid out below it. Opaque, so no hard
/// divider: the separation appears only once content actually passes beneath
/// the bar, as a soft edge that the content fades into.
class DetailAppBar extends StatefulWidget implements PreferredSizeWidget {
  const DetailAppBar({
    this.title,
    this.subtitle,
    this.onBack,
    this.actions,
    this.centerTitle = false,
    super.key,
  });
  final String? title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget>? actions;
  final bool centerTitle;

  @override
  Size get preferredSize => const Size.fromHeight(AppBarMetrics.barHeight);

  @override
  State<DetailAppBar> createState() => _DetailAppBarState();
}

class _DetailAppBarState extends State<DetailAppBar> {
  ScrollNotificationObserverState? _observer;
  bool _scrolledUnder = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handleScrollNotification);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handleScrollNotification);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handleScrollNotification);
    _observer = null;
    super.dispose();
  }

  void _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return;
    if (!defaultScrollNotificationPredicate(notification)) return;
    final metrics = notification.metrics;
    final bool under;
    switch (metrics.axisDirection) {
      case AxisDirection.down:
        under = metrics.extentBefore > 0;
      case AxisDirection.up:
        under = metrics.extentAfter > 0;
      case AxisDirection.left:
      case AxisDirection.right:
        // Horizontal scrollers under the bar say nothing about whether
        // vertical content has passed beneath it.
        return;
    }
    if (under != _scrolledUnder) setState(() => _scrolledUnder = under);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppMotion.short,
      curve: AppMotion.easeOut,
      decoration: BoxDecoration(
        color: cs.surface,
        // A surface-coloured spread below the bar, not a line: content
        // scrolling up dissolves into the bar instead of hitting a rule.
        boxShadow: [
          if (_scrolledUnder)
            BoxShadow(
              color: cs.surface,
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppBarMetrics.barHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space4,
              AppTheme.space4,
              AppTheme.space8,
              AppTheme.space4,
            ),
            child: NavigationToolbar(
              leading: AppBarBackButton(onTap: widget.onBack),
              middle: widget.title != null
                  ? _Title(
                      widget.title!,
                      widget.subtitle,
                      textAlign: widget.centerTitle
                          ? TextAlign.center
                          : TextAlign.left,
                    )
                  : null,
              trailing: widget.actions != null && widget.actions!.isNotEmpty
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: widget.actions!,
                    )
                  : null,
              centerMiddle: widget.centerTitle,
              middleSpacing: 8,
            ),
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.title, this.subtitle, {this.textAlign});
  final String title;
  final String? subtitle;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final align = textAlign ?? TextAlign.start;
    final titleText = Text(
      title,
      style: AppTextStyles.bodyLarge.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
        height: subtitle != null ? 1.2 : null,
      ),
      textAlign: align,
      overflow: TextOverflow.ellipsis,
    );
    if (subtitle == null) return titleText;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        titleText,
        Text(
          subtitle!,
          style: AppTextStyles.bodySmall.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.2,
            // Subtitles here are dates and counts; without tabular figures
            // they reflow by a pixel every time the value ticks.
            fontFeatures: AppTextStyles.tabularFigures,
          ),
          textAlign: align,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
