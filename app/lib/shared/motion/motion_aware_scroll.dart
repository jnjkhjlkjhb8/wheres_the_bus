import 'package:flutter/widgets.dart';

extension MotionAwareScroll on ScrollController {
  /// Jumps instead of tweening when the system asks for reduced motion.
  Future<void> jumpOrAnimateTo(
    double offset, {
    required bool reduced,
    required Duration duration,
    required Curve curve,
  }) {
    if (reduced) {
      jumpTo(offset);
      return Future<void>.value();
    }
    return animateTo(offset, duration: duration, curve: curve);
  }
}
