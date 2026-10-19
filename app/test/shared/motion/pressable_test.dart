import 'package:flutter/gestures.dart' show kLongPressTimeout, kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    Pressable child, {
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(child: child),
      ),
    ),
  );

  testWidgets('tap presses, releases and calls the action once', (
    tester,
  ) async {
    var calls = 0;
    await pump(
      tester,
      Pressable(
        onTap: () => calls++,
        child: const SizedBox(width: 20, height: 20),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      AppMotion.pressedScale,
    );
    await gesture.up();
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('cancel releases without firing and reduced motion is instant', (
    tester,
  ) async {
    var calls = 0;
    await pump(
      tester,
      Pressable(
        onTap: () => calls++,
        minTapSize: 48,
        child: const SizedBox(width: 20, height: 20),
      ),
      reduced: true,
    );
    expect(tester.getSize(find.byType(Pressable)), const Size(48, 48));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(calls, 0);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('long press fires alone and disabled actions are inert', (
    tester,
  ) async {
    var calls = 0;
    for (final enabled in [true, false]) {
      await pump(
        tester,
        Pressable(
          onLongPress: () => calls++,
          enabled: enabled,
          child: const SizedBox(width: 20, height: 20),
        ),
      );
      await tester.longPress(find.byType(Pressable));
      await tester.pump();
      expect(calls, 1);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    }
    await pump(tester, const Pressable(child: SizedBox(width: 20, height: 20)));
    await tester.tap(find.byType(Pressable));
    expect(calls, 1);
  });

  double scale(WidgetTester tester) =>
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

  testWidgets('a Pressable with no action gives no press feedback', (
    tester,
  ) async {
    await pump(tester, const Pressable(child: SizedBox(width: 20, height: 20)));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump();
    expect(scale(tester), 1);
    await gesture.up();
  });

  testWidgets('a long-press-only Pressable presses and releases on hold', (
    tester,
  ) async {
    var calls = 0;
    await pump(
      tester,
      Pressable(
        onLongPress: () => calls++,
        child: const SizedBox(width: 20, height: 20),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    // Competing with the long press, the tap-down waits out kPressTimeout.
    await tester.pump(kPressTimeout + const Duration(milliseconds: 10));
    expect(scale(tester), AppMotion.pressedScale);
    await tester.pump(kLongPressTimeout);
    expect(calls, 1);
    expect(scale(tester), 1);
    await gesture.up();
  });
}
