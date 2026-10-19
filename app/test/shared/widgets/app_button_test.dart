import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';

void main() {
  testWidgets('each variant retains icon layout, disabled state and one tap', (
    tester,
  ) async {
    var calls = 0;
    final factories = [
      AppButton.new,
      AppButton.outlined,
      AppButton.text,
      AppButton.destructive,
    ];
    for (final factory in factories) {
      for (final icon in [null, Icons.train]) {
        for (final enabled in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: factory(
                    label: 'Action',
                    icon: icon,
                    onPressed: enabled ? () => calls++ : null,
                  ),
                ),
              ),
            ),
          );
          expect(find.text('Action'), findsOneWidget);
          expect(
            find.byIcon(Icons.train),
            icon == null ? findsNothing : findsOneWidget,
          );
          final before = calls;
          final gesture = await tester.startGesture(
            tester.getCenter(find.text('Action')),
          );
          await tester.pump();
          expect(
            tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
            enabled ? AppMotion.pressedScale : 1,
          );
          await gesture.up();
          await tester.pumpAndSettle();
          expect(calls, before + (enabled ? 1 : 0));
          expect(
            tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
            1,
          );
        }
      }
    }
  });

  testWidgets('cancel restores scale and reduced motion has no animation', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(
            child: AppButton(label: 'Action', onPressed: () => calls++),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Action')),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
    );
    await gesture.cancel();
    await tester.pump();
    expect(calls, 0);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });
}
