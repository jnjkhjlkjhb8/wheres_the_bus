import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

Widget _switcher(String kind) => MaterialApp(
  home: AnimatedSwitcher(
    duration: AppMotion.short,
    transitionBuilder: AppMotion.switchFade,
    child: KeyedSubtree(key: ValueKey(kind), child: Text(kind)),
  ),
);

void main() {
  testWidgets('a key returning mid-transition does not duplicate', (
    tester,
  ) async {
    // Two round trips inside one transition: the switcher only dedupes an
    // outgoing entry against the current one, so the second 'error' leaves
    // two identically keyed entries fading out at once.
    await tester.pumpWidget(_switcher('error'));
    for (final kind in ['loading', 'error', 'loading']) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(_switcher(kind));
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
