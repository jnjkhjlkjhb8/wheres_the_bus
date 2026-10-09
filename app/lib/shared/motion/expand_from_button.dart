import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import 'package:wheres_the_bus/shared/motion/app_motion.dart';

class ExpandFromButton<T> extends StatelessWidget {
  const ExpandFromButton({
    required this.button,
    required this.screen,
    super.key,
    this.closedShape = const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    this.closedColor = Colors.transparent,
    this.openColor,
    this.clipBehavior = Clip.none,
    this.onClosed,
  });

  final CloseContainerBuilder button;
  final OpenContainerBuilder<T> screen;
  final ShapeBorder closedShape;
  final Color closedColor;
  final Color? openColor;
  final Clip clipBehavior;
  final ClosedCallback<T?>? onClosed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return OpenContainer<T>(
      transitionType: ContainerTransitionType.fadeThrough,
      transitionDuration: reduceMotion
          ? AppMotion.instant
          : const Duration(milliseconds: 320),
      closedShape: closedShape,
      closedElevation: 0,
      openElevation: 0,
      closedColor: closedColor,
      openColor: openColor ?? scheme.surface,
      middleColor: openColor ?? scheme.surface,
      clipBehavior: clipBehavior,
      onClosed: onClosed,
      closedBuilder: button,
      openBuilder: screen,
    );
  }
}
