import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class AlightTrackBell extends StatelessWidget {
  const AlightTrackBell({
    required this.active,
    required this.onTap,
    required this.semanticLabel,
    super.key,
  });

  /// Whether a tracking session is running for this particular vehicle.
  final bool active;

  final VoidCallback onTap;

  /// Must describe the outcome of the tap, which flips with [active]: setting
  /// a reminder versus cancelling one.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      semanticLabel: semanticLabel,
      onTap: () {
        // A commit either way — starting a session or ending one.
        unawaited(HapticService.instance.mediumTap());
        onTap();
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? cs.onSurface : cs.surface,
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Icon(
              active
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              size: 18,
              color: active ? cs.surface : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
