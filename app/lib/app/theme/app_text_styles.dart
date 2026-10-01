import 'package:flutter/material.dart';

class AppTextStyles {
  AppTextStyles._();

  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  static const TextStyle heading1 = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w700,
    fontSize: 24,
    height: 1.3,
    letterSpacing: -0.48,
  );

  static const TextStyle heading2 = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w600,
    fontSize: 18,
    height: 1.3,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 1.5,
  );

  static const TextStyle bodyRegular = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 1.5,
  );

  static const TextStyle bodySmall = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 1.4,
    letterSpacing: 0.1,
  );

  static const TextStyle bodyVerySmall = TextStyle(
    fontFamily: 'IBMPlexSans',
    fontWeight: FontWeight.w400,
    fontSize: 10,
    height: 1.4,
    letterSpacing: 0.15,
  );

  static const TextStyle memo = TextStyle(
    fontFamily: 'IBMPlexMono',
    fontWeight: FontWeight.w400,
    fontSize: 13,
    height: 1.4,
  );

  static TextStyle timeValue({
    double? size,
    FontWeight? weight,
    Color? color,
    TextDecoration? decoration,
    double? height,
    double? letterSpacing,
  }) => memo.copyWith(
    fontSize: size,
    fontWeight: weight,
    color: color,
    decoration: decoration,
    height: height,
    letterSpacing: letterSpacing,
    fontFeatures: tabularFigures,
  );
}
