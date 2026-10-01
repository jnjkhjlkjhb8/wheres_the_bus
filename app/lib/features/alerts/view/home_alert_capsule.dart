import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

/// Height matches the 44px floating controls the capsule sits between.
const double _kCapsuleHeight = 44;

class HomeAlertCapsule extends StatelessWidget {
  const HomeAlertCapsule({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AlertBloc, AlertState>(
      buildWhen: (prev, curr) =>
          prev.redAlerts.firstOrNull?.message !=
              curr.redAlerts.firstOrNull?.message ||
          prev.redAlerts.length != curr.redAlerts.length,
      builder: (context, state) {
        final alerts = state.redAlerts;
        final alert = alerts.firstOrNull;
        if (alert == null) return const SizedBox.shrink();
        return _AlertCapsule(alert: alert, extra: alerts.length - 1);
      },
    );
  }
}

class _AlertCapsule extends StatefulWidget {
  const _AlertCapsule({required this.alert, required this.extra});

  final AlertViewModel alert;
  final int extra;

  @override
  State<_AlertCapsule> createState() => _AlertCapsuleState();
}

/// How long the full message stays expanded before tucking into the capsule.
const Duration _kExpandedHold = Duration(seconds: 4);

class _AlertCapsuleState extends State<_AlertCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _reveal;
  late final Animation<double> _surfaceFade;
  late final Animation<double> _contentFade;

  /// Arrival shows the full multi-line message; after [_kExpandedHold] it
  /// collapses to the resident single-line capsule.
  bool _expanded = true;
  Timer? _collapseTimer;

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_kExpandedHold, () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleCollapse();
    _ctrl = AnimationController(vsync: this, duration: AppMotion.sheet);
    // Never from zero width: the reveal starts at roughly the footprint of
    // the neighboring 44px circular controls, then spreads outward.
    _reveal = Tween<double>(begin: 0.15, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: AppMotion.easeOut),
    );
    _surfaceFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0, 0.25, curve: AppMotion.easeOut),
    );
    // Text waits until the capsule has opened enough to hold it, so early
    // frames read as material expanding rather than clipped words.
    _contentFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 1, curve: AppMotion.easeOut),
    );
    if (AppMotion.reduced(context)) {
      _ctrl.value = 1;
    } else {
      unawaited(_ctrl.forward());
    }
  }

  @override
  void didUpdateWidget(covariant _AlertCapsule old) {
    super.didUpdateWidget(old);
    // A replacement alert replays the outward expansion so the change reads
    // as a new notice, not silently swapped text.
    if (widget.alert.message != old.alert.message) {
      _expanded = true;
      _scheduleCollapse();
      if (AppMotion.reduced(context)) {
        _ctrl.value = 1;
      } else {
        unawaited(_ctrl.forward(from: 0));
      }
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final colors = noticeColors(alert.tone, cs);
    final label = widget.extra > 0
        ? AppI18n.of(context).alertPlusMoreAndDetails(
            alert.title ?? alert.message,
            widget.extra,
          )
        : AppI18n.of(
            context,
          ).alertAndDetails(alert.title ?? alert.message);

    return Dismissible(
      key: ValueKey(alert.message),
      direction: DismissDirection.up,
      onDismissed: (_) =>
          context.read<AlertBloc>().add(AlertDismissed(alert.message)),
      child: Pressable(
        onTap: () => unawaited(showNotificationSheet(context)),
        semanticLabel: label,
        child: FadeTransition(
          opacity: _surfaceFade,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_kCapsuleHeight / 2),
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (context, child) => Align(
                widthFactor: _reveal.value,
                heightFactor: 1,
                child: child,
              ),
              // Height eases shut when the hold expires; padding rides along
              // because the whole container sits inside the AnimatedSize.
              child: AnimatedSize(
                duration: AppMotion.reduced(context)
                    ? AppMotion.instant
                    : AppMotion.sheet,
                curve: AppMotion.easeOut,
                alignment: Alignment.topCenter,
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: _kCapsuleHeight,
                  ),
                  padding: _expanded
                      ? const EdgeInsets.fromLTRB(
                          AppTheme.space16,
                          AppTheme.space12,
                          AppTheme.space16,
                          AppTheme.space12,
                        )
                      : const EdgeInsets.symmetric(
                          horizontal: AppTheme.space14,
                        ),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(_kCapsuleHeight / 2),
                    // Same elevation treatment as floatingControl: shadow on
                    // the light map, hairline border where a shadow would
                    // vanish.
                    border: dark ? Border.all(color: cs.outlineVariant) : null,
                    boxShadow: dark ? const [] : AppShadows.floating,
                  ),
                  child: FadeTransition(
                    opacity: _contentFade,
                    child: AnimatedSwitcher(
                      duration: AppMotion.reduced(context)
                          ? AppMotion.instant
                          : AppMotion.short,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.easeOut,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: AnimatedBuilder(
                          animation: anim,
                          builder: (_, blurred) {
                            final sigma = (1 - anim.value) * 2;
                            if (sigma == 0) return blurred!;
                            return ImageFiltered(
                              imageFilter: ui.ImageFilter.blur(
                                sigmaX: sigma,
                                sigmaY: sigma,
                              ),
                              child: blurred,
                            );
                          },
                          child: child,
                        ),
                      ),
                      child: Row(
                        key: ValueKey(_expanded),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: _expanded
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.center,
                        spacing: AppTheme.space6,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(top: _expanded ? 1 : 0),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: colors.accent,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              _expanded
                                  ? alert.message
                                  : (alert.title ?? alert.message),
                              style: AppTextStyles.bodySmall.copyWith(
                                color: colors.ink,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: _expanded ? 4 : 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (widget.extra > 0)
                            Text(
                              '+${widget.extra}',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: colors.ink,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
