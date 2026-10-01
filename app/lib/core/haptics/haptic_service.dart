import 'dart:async';
import 'package:flutter/services.dart';

/// Centralised haptic feedback — including the 6.7-second sustained bus
/// arrival vibration.
class HapticService {
  HapticService._();
  static final HapticService instance = HapticService._();

  Timer? _sustainedTimer;

  Future<void> lightTap() => HapticFeedback.lightImpact();
  Future<void> mediumTap() => HapticFeedback.mediumImpact();
  Future<void> heavyTap() => HapticFeedback.heavyImpact();
  Future<void> selectionClick() => HapticFeedback.selectionClick();

  Future<void> shortAlightPulse() async {
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.mediumImpact();
  }

  void longAlightPulse() {
    _sustainedTimer?.cancel();
    const pulseInterval = Duration(milliseconds: 130);
    final endTime = DateTime.now().add(const Duration(milliseconds: 1600));
    unawaited(HapticFeedback.heavyImpact());
    _sustainedTimer = Timer.periodic(pulseInterval, (timer) {
      if (DateTime.now().isAfter(endTime)) {
        timer.cancel();
        _sustainedTimer = null;
        return;
      }
      unawaited(HapticFeedback.heavyImpact());
    });
  }

  void stopAlightPulse() {
    _sustainedTimer?.cancel();
    _sustainedTimer = null;
  }
}
