import 'package:flutter/material.dart';

class AppShadows {
  AppShadows._();

  /// Drop shadows only read against light surfaces. On dark ones they are
  /// invisible, so elevation is carried by a lighter surface instead and the
  /// blur pass is skipped rather than painted for nothing.
  static List<BoxShadow> cardFor(Brightness brightness) =>
      brightness == Brightness.dark ? const [] : card;

  // Layered like real light: a tight contact shadow, a mid-range one, and a
  // wide ambient one. Each layer alone would read as a halo.
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0A000000), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 2), blurRadius: 6),
    BoxShadow(color: Color(0x0A000000), offset: Offset(0, 6), blurRadius: 16),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 4), blurRadius: 10),
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 12), blurRadius: 28),
  ];

  static const List<BoxShadow> bottomSheet = [
    BoxShadow(
      color: Color(0x4D000000),
      offset: Offset(0, 1),
      blurRadius: 3,
    ),
    BoxShadow(
      color: Color(0x26000000),
      offset: Offset(0, 4),
      blurRadius: 8,
      spreadRadius: 3,
    ),
  ];

  /// Thumb of a sliding segment control; dark mode swaps the diffuse shadow
  /// for a tight, stronger one because a wide blur disappears there.
  static List<BoxShadow> segmentThumbFor(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? .25 : .05),
        blurRadius: dark ? 2 : 4,
        offset: Offset(0, dark ? 1 : 2),
      ),
    ];
  }

  /// A page lifted off the stack during a predictive-back drag; [opacity]
  /// follows the gesture.
  static List<BoxShadow> lifted(double opacity) => [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, opacity),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  /// Surface-coloured spread under an app bar so scrolled content dissolves
  /// into it instead of meeting a hairline.
  static List<BoxShadow> scrolledUnder(Color surface) => [
    BoxShadow(color: surface, blurRadius: 12, offset: const Offset(0, 6)),
  ];
}
