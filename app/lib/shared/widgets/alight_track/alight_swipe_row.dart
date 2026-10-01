import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';

/// How far the row travels before the gesture commits. A deliberate pull, not
/// a nudge — the rows above and below scroll, so an easy threshold would arm a
/// reminder every time a thumb drifted sideways mid-scroll.
const double _kLatchFraction = 0.35;

class AlightSwipeRow extends StatelessWidget {
  const AlightSwipeRow({
    required this.rowKey,
    required this.onSwiped,
    required this.child,
    super.key,
  });

  /// Identifies the row across rebuilds. Live ETA frames reorder and reinsert
  /// vehicle markers constantly; without a stable key a swipe in progress
  /// would be handed to whichever marker landed at that index next.
  final String rowKey;

  final VoidCallback onSwiped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('alight-swipe-$rowKey'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: _kLatchFraction},
      onUpdate: (details) {
        // `reached` flips exactly once per crossing, which is the callback the
        // gesture needs and the only reason this is Dismissible rather than a
        // hand-rolled recogniser.
        if (details.reached && !details.previousReached) {
          unawaited(HapticService.instance.selectionClick());
        }
      },
      confirmDismiss: (_) async {
        onSwiped();
        return false;
      },
      background: Container(
        color: cs.onSurface,
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space20),
        // The same glyph that will mark the chosen 下車站 once the flow is
        // open: the gesture and its result share one symbol, so the second
        // time a rider sees it they already know what it meant.
        child: Icon(Icons.download_rounded, size: 20, color: cs.surface),
      ),
      child: ConstrainedBox(
        // The bare divider is ~29px, under the minimum target for a gesture
        // that has to win against the list's own scroll.
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(child: child),
      ),
    );
  }
}
