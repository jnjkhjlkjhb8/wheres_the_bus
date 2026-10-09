import 'package:flutter/material.dart';

class AppShadows {
  AppShadows._();

  /// Drop shadows only read against light surfaces. On dark ones they are
  /// invisible, so elevation is carried by a lighter surface instead and the
  /// blur pass is skipped rather than painted for nothing.
  static List<BoxShadow> cardFor(Brightness brightness) =>
      brightness == Brightness.dark ? const [] : card;

  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x14000000),
      offset: Offset(0, 2),
      blurRadius: 8,
    ),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(
      color: Color(0x1F000000),
      offset: Offset(0, 4),
      blurRadius: 16,
    ),
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
}
