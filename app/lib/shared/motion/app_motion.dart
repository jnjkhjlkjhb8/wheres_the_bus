import 'package:flutter/material.dart';

/// Shared motion timings and curves for the app.
abstract final class AppMotion {
  /// No animation.
  static const Duration instant = Duration.zero;

  /// Press feedback duration.
  static const Duration press = Duration(milliseconds: 110);

  /// Micro transition duration (color/selection changes).
  static const Duration micro = Duration(milliseconds: 150);

  /// Short transition duration.
  static const Duration short = Duration(milliseconds: 180);

  /// Medium transition duration.
  static const Duration medium = Duration(milliseconds: 240);

  /// Sheet transition duration.
  static const Duration sheet = Duration(milliseconds: 280);

  /// Loop duration for shimmer/skeleton loading placeholders.
  static const Duration shimmerLoop = Duration(milliseconds: 900);

  /// One-shot map scan sweep confirming a deliberate nearby search covered an
  /// area. Longer than a UI transition because it travels the width of the
  /// screen; it conveys reach, not a state change.
  static const Duration scan = Duration(milliseconds: 700);

  /// The quiet variant of [scan]: the ring fades in and out at its final size,
  /// so the area is still stated but nothing travels. Used for the frequent,
  /// incidental searches a map pan triggers, and for reduce-motion throughout.
  static const Duration scanStill = Duration(milliseconds: 480);

  /// Expressive ease-out curve.
  static const Curve easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Expressive ease-in-out curve.
  static const Curve easeInOut = Cubic(0.77, 0, 0.175, 1);

  /// Drawer transition curve.
  static const Curve drawer = Cubic(0.32, 0.72, 0, 1);

  /// Scale applied while a pressable surface is pressed.
  static const double pressedScale = 0.97;

  /// Critically damped spring for standard gesture settles (~0.35s response).
  /// Use with `AnimationController.animateWith(SpringSimulation(...))`,
  /// seeding the release velocity from the drag's `DragEndDetails`.
  static final SpringDescription spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 322, // (2π / 0.35s)²
  );

  /// Slightly under-damped spring for settles after a momentum flick.
  /// Only use when the gesture itself carried velocity; never on plain taps.
  static final SpringDescription springMomentum =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 322,
        ratio: 0.8,
      );

  /// Single accessor for the reduce-motion signal so call sites stay uniform.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Widget switchFade(Widget child, Animation<double> animation) =>
      FadeTransition(opacity: animation, child: child);
}
