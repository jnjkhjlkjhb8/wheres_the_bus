import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/native_controls.dart';

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

  void _commit() {
    // A commit either way — starting a session or ending one.
    unawaited(HapticService.instance.mediumTap());
    onTap();
  }

  @override
  Widget build(BuildContext context) => UiKitBarScope.of(context)
      ? NativeIconButton(
          symbol: active ? 'bell.badge.fill' : 'bell',
          label: semanticLabel,
          prominent: active,
          onTap: _commit,
        )
      : _drawn(Theme.of(context).colorScheme);

  Widget _drawn(ColorScheme cs) => Pressable(
    semanticLabel: semanticLabel,
    onTap: _commit,
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
