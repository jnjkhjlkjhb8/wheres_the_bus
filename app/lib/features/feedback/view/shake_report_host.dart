import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:smooth_sheets/smooth_sheets.dart' show SheetOffset;
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/sensors/shake_recognizer.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

class ShakeReportHost extends StatefulWidget {
  const ShakeReportHost({required this.child, this.samples, super.key});

  final Widget child;

  /// Overrides the device accelerometer. Production leaves this null; tests
  /// drive a broadcast stream through it, because no simulator reports motion
  /// and this path can otherwise only be checked by hand on real hardware.
  @visibleForTesting
  final Stream<UserAccelerometerEvent>? samples;

  @override
  State<ShakeReportHost> createState() => _ShakeReportHostState();
}

class _ShakeReportHostState extends State<ShakeReportHost> {
  final _recognizer = ShakeRecognizer();

  /// Sample clock. A stopwatch rather than wall time: it is monotonic, and it
  /// pauses with the subscription, so the gap a backgrounded app leaves can
  /// never be mistaken for elapsed shake time.
  final _clock = Stopwatch();

  StreamSubscription<UserAccelerometerEvent>? _samples;
  ValueListenable<Box<dynamic>>? _setting;
  AppLifecycleListener? _lifecycle;

  bool _resumed = true;

  /// True from the moment a shake is accepted until the rider answers the
  /// sheet, so a second shake while the question is on screen is ignored
  /// rather than stacking another copy of it.
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _resumed = state == AppLifecycleState.resumed;
        _sync();
      },
    );
    if (HiveStore.settingsReady) {
      _setting = HiveStore.settings.listenable(
        keys: const [SettingsRepository.shakeToReportKey],
      )..addListener(_sync);
    }
    _sync();
  }

  @override
  void dispose() {
    _setting?.removeListener(_sync);
    _lifecycle?.dispose();
    unawaited(_samples?.cancel());
    super.dispose();
  }

  /// Attaches or drops the accelerometer stream to match the current setting
  /// and lifecycle state. Idempotent, so both listeners can call it freely.
  void _sync() {
    final wanted = _resumed && SettingsRepository.instance.shakeToReport;
    if (wanted == (_samples != null)) return;
    if (!wanted) {
      unawaited(_samples?.cancel());
      _samples = null;
      _clock.stop();
      // A half-finished shake must not survive the gap and complete itself
      // against a peak from minutes later.
      _recognizer.reset();
      return;
    }
    _clock.start();
    _samples =
        (widget.samples ??
                userAccelerometerEventStream(
                  // 50 Hz. The default 5 Hz samples too coarsely to see a hand
                  // change direction, which is the whole signal this reads.
                  samplingPeriod: SensorInterval.gameInterval,
                ))
            .listen(
              _onSample,
              // A device without a usable accelerometer simply never
              // asks; there is nothing to tell the rider, since every
              // other way into the form still works.
              onError: (Object _) {},
            );
  }

  void _onSample(UserAccelerometerEvent event) {
    if (_asking || !mounted) return;
    final shaken = _recognizer.add(
      x: event.x,
      y: event.y,
      z: event.z,
      at: _clock.elapsed,
    );
    if (shaken) unawaited(_ask());
  }

  Future<void> _ask() async {
    final router = GoRouter.of(context);
    // Already on the form. Answering a shake with the screen it would open is
    // an interface that isn't listening.
    if (router.state.fullPath == AppRoutes.feedback) return;

    // The concrete location, not the pattern: `/bus/route/:subRouteUid` names
    // no route and `/near/bus/:id` names the stop, and "which one" is what a
    // report about a stop is for.
    final screen = router.state.uri.toString();

    _asking = true;
    // Before the sheet, not with it: the tap is the app saying it felt the
    // shake, and it has to land on the gesture rather than after the animation.
    unawaited(HapticService.instance.lightTap());
    bool? confirmed;
    try {
      confirmed = await ShakeReportSheet.show(context);
    } finally {
      // In a finally: a flag left latched by a failed presentation would
      // silence the gesture for the rest of the session, with nothing on
      // screen to explain why shaking had stopped working.
      _asking = false;
    }
    if (!mounted || confirmed != true) return;
    unawaited(router.push(AppRoutes.feedbackLocation(from: screen)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ShakeReportSheet extends StatelessWidget {
  const ShakeReportSheet({super.key});

  /// Resolves true when the rider chose to report.
  static Future<bool?> show(BuildContext context) {
    // All three detents are the content's own height: there is nothing to
    // resize to, so the sheet only ever arrives or leaves.
    const height = SheetOffset(1);
    return BottomSheetShell.show<bool>(
      context: context,
      initialOffset: height,
      minOffset: height,
      maxOffset: height,
      child: const ShakeReportSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space4,
        AppTheme.space20,
        AppTheme.space20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i18n.shakeReportTitle, style: AppTextStyles.heading1),
          const SizedBox(height: AppTheme.space8),
          // Says why the sheet appeared before it says what it wants. A rider
          // who shook the phone by accident needs the cause named first,
          // otherwise the sheet reads as the app malfunctioning.
          Text(
            i18n.shakeReportBody,
            style: AppTextStyles.bodyRegular.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          // Wide enough to read as an aside rather than a third line of the
          // same paragraph — it answers a question the sheet did not ask.
          const SizedBox(height: AppTheme.space12),
          // bodySmall, not the mono memo style: mono is reserved for times and
          // reference numbers, and this is a sentence.
          Text(
            i18n.shakeReportOptOutHint,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: AppTheme.space20),
          Row(
            children: [
              Expanded(
                child: _SheetButton(
                  label: i18n.shakeReportDismiss,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppTheme.space12),
              Expanded(
                child: _SheetButton(
                  label: i18n.feedbackTitle,
                  primary: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? cs.onSurface : null,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
          border: primary ? null : Border.all(color: cs.outline),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodyLarge.copyWith(
            fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
            color: primary ? cs.surface : cs.onSurface,
          ),
        ),
      ),
    );
  }
}
