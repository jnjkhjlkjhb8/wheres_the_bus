import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fades [child]'s trailing [extent] px to transparent so scrolled rows
/// dissolve into the edge instead of being cut by it.
class EdgeFade extends StatelessWidget {
  const EdgeFade({required this.child, super.key, this.extent = 24});

  final Widget child;
  final double extent;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.black, Colors.black, Colors.transparent],
        stops: [
          0,
          math.max(0.0, (bounds.height - extent) / bounds.height),
          1,
        ],
      ).createShader(bounds),
      child: child,
    );
  }
}
