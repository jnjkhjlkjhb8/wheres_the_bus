import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';
import 'package:wheres_the_bus/features/alerts/view/alert_source_chip.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class NotificationToastHost extends StatefulWidget {
  const NotificationToastHost({required this.child, super.key});

  final Widget child;

  @override
  State<NotificationToastHost> createState() => _NotificationToastHostState();
}

class _NotificationToastHostState extends State<NotificationToastHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  AlertViewModel? _current;
  final Set<String> _shown = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.sheet,
      reverseDuration: AppMotion.short,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Home presents arriving disruptions itself, in the map capsule that sits
  /// between its floating controls. Toasting the same notice on top of it
  /// would announce one event twice and cover the capsule doing it.
  bool get _homeOwnsInterrupt => AppRoutes.isHomeLocation(
    AppRouter.router.routerDelegate.currentConfiguration.uri,
  );

  void _present(AlertViewModel alert) {
    _timer?.cancel();
    setState(() => _current = alert);
    // Retarget from the current value instead of snapping to hidden first:
    // a second alert arriving mid-display swaps content in place rather than
    // replaying the entrance from scratch.
    unawaited(_controller.forward());
    _timer = Timer(const Duration(seconds: 5), _hide);
  }

  Future<void> _hide() async {
    _timer?.cancel();
    if (!mounted || _current == null) return;
    await _controller.reverse();
    if (!mounted) return;
    setState(() => _current = null);
  }

  /// Finalizes a gesture-driven dismissal: the drag already spring-settled
  /// the controller to 0, so this only clears the content — no re-animation.
  void _finalizeDismiss() {
    _timer?.cancel();
    if (!mounted || _current == null) return;
    setState(() => _current = null);
  }

  void _pauseAutoHide() => _timer?.cancel();

  void _resumeAutoHide() {
    if (_current == null) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _hide);
  }

  void _openInbox() {
    final ctx = AppRouter.rootNavigatorKey.currentContext;
    unawaited(_hide());
    if (ctx != null) unawaited(showNotificationSheet(ctx));
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AlertBloc, AlertState>(
      listenWhen: (_, c) => c.redAlerts.any((a) => !_shown.contains(a.message)),
      listener: (context, state) {
        final fresh = state.redAlerts
            .where((a) => !_shown.contains(a.message))
            .toList();
        if (fresh.isEmpty) return;
        final latest = fresh.last;
        // Marked shown either way: once home's capsule has announced a
        // notice, walking to another screen must not replay it as a toast.
        _shown.add(latest.message);
        if (_homeOwnsInterrupt) return;
        _present(latest);
      },
      child: Stack(
        children: [
          widget.child,
          if (_current != null)
            _ToastLayer(
              controller: _controller,
              alert: _current!,
              onTap: _openInbox,
              onDismissed: _finalizeDismiss,
              onInteractionStart: _pauseAutoHide,
              onInteractionEnd: _resumeAutoHide,
            ),
        ],
      ),
    );
  }
}

class _ToastLayer extends StatefulWidget {
  const _ToastLayer({
    required this.controller,
    required this.alert,
    required this.onTap,
    required this.onDismissed,
    required this.onInteractionStart,
    required this.onInteractionEnd,
  });

  final AnimationController controller;
  final AlertViewModel alert;
  final VoidCallback onTap;

  /// The drag settled below the dismiss threshold — clear the toast content.
  final VoidCallback onDismissed;

  /// A drag grabbed the toast; the caller pauses the auto-hide timer so it
  /// doesn't fire out from under the gesture.
  final VoidCallback onInteractionStart;

  /// The drag released back to fully shown; the caller resumes auto-hide.
  final VoidCallback onInteractionEnd;

  @override
  State<_ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<_ToastLayer> {
  // Upward drag distance, in px, that fully dismisses the toast.
  static const double _dismissDistance = 120;
  // Below this release speed (px/s) the gesture is treated as a hold-and-
  // release rather than a flick, so position decides commit vs. return.
  static const double _flickVelocityThreshold = 200;

  double _dragStartValue = 1;
  double _dragAccumDy = 0;
  bool _dragging = false;

  void _onDragStart(DragStartDetails details) {
    _dragging = true;
    widget.controller.stop();
    widget.onInteractionStart();
    _dragStartValue = widget.controller.value;
    _dragAccumDy = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragAccumDy += details.delta.dy;
    double target;
    if (_dragAccumDy <= 0) {
      // Dragging up: the toast tracks the finger 1:1 toward dismissed.
      target = _dragStartValue + _dragAccumDy / _dismissDistance;
    } else {
      // Dragging down past fully shown: progressive resistance:
      // each further pixel moves the value less, asymptoting at 1.
      final excess = _dragAccumDy / _dismissDistance;
      final resisted = excess / (1 + excess);
      target = _dragStartValue + resisted;
    }
    widget.controller.value = target.clamp(0.0, 1.0);
  }

  void _onDragCancel() {
    // Treat a cancelled gesture as a zero-velocity release so the toast
    // settles instead of hanging mid-position with auto-hide paused.
    _onDragEnd(DragEndDetails());
  }

  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    final velocityY = details.velocity.pixelsPerSecond.dy;
    final dismiss = velocityY.abs() > _flickVelocityThreshold
        ? velocityY < 0
        : widget.controller.value < 0.5;
    final target = dismiss ? 0.0 : 1.0;

    if (AppMotion.reduced(context)) {
      widget.controller.value = target;
      _afterSettle(dismiss: dismiss);
      return;
    }

    // Convert the release's pixel velocity into controller-value velocity
    // (value decreases as the toast moves up) so the spring inherits it.
    final simVelocity = -velocityY / _dismissDistance;
    final sim = SpringSimulation(
      AppMotion.spring,
      widget.controller.value,
      target,
      simVelocity,
    );
    unawaited(
      widget.controller
          .animateWith(sim)
          .then((_) => _afterSettle(dismiss: dismiss)),
    );
  }

  void _afterSettle({required bool dismiss}) {
    if (!mounted || _dragging) return;
    if (dismiss) {
      widget.onDismissed();
    } else {
      widget.onInteractionEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final alert = widget.alert;
    // Scoped aspects so keyboard/inset changes don't rebuild the toast.
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 16,
      right: 16,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final t = AppMotion.easeOut.transform(controller.value);
          return Opacity(
            opacity: reduce ? (controller.value > 0 ? 1 : 0) : t,
            child: Transform.translate(
              offset: reduce ? Offset.zero : Offset(0, (1 - t) * -16),
              child: Transform.scale(
                scale: reduce ? 1 : 0.94 + 0.06 * t,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          );
        },
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            // The vertical drag recognizer lives here, outside Pressable, so
            // a drag can grab the toast mid-entrance or mid-auto-hide while
            // Pressable still owns tap press-state and semantics.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: _onDragStart,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              onVerticalDragCancel: _onDragCancel,
              child: Pressable(
                onTap: widget.onTap,
                semanticLabel: alert.title ?? alert.message,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.space14,
                    vertical: AppTheme.space12,
                  ),
                  decoration: BoxDecoration(
                    color: cs.brightness == Brightness.light
                        ? Colors.white
                        : cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppTheme.radiusCard),
                    boxShadow: AppShadows.floating,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: AlertSourceChip(
                          source: alert.source,
                          department: alert.department,
                        ),
                      ),
                      const SizedBox(width: AppTheme.space12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alert.title ?? alert.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodyRegular.copyWith(
                                fontSize: 13.5,
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: AppTheme.space2),
                            Text(
                              AppI18n.of(context).alertJustNowDisruption,
                              style: AppTextStyles.memo.copyWith(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppTheme.space8),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: cs.outline,
                      ),
                    ],
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
