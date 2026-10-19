import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

void _expectCubic(Curve curve, double a, double b, double c, double d) {
  expect(curve, isA<Cubic>());
  final cubic = curve as Cubic;
  expect(cubic.a, a);
  expect(cubic.b, b);
  expect(cubic.c, c);
  expect(cubic.d, d);
}

void main() {
  test('durations keep their documented milliseconds', () {
    expect(AppMotion.instant, Duration.zero);
    expect(AppMotion.press, const Duration(milliseconds: 110));
    expect(AppMotion.micro, const Duration(milliseconds: 150));
    expect(AppMotion.short, const Duration(milliseconds: 180));
    expect(AppMotion.medium, const Duration(milliseconds: 240));
    expect(AppMotion.sheet, const Duration(milliseconds: 280));
    expect(AppMotion.shimmerLoop, const Duration(milliseconds: 900));
    expect(AppMotion.scan, const Duration(milliseconds: 700));
    expect(AppMotion.scanStill, const Duration(milliseconds: 480));
  });

  test('curves keep their control points', () {
    _expectCubic(AppMotion.easeOut, 0.23, 1, 0.32, 1);
    _expectCubic(AppMotion.easeInOut, 0.77, 0, 0.175, 1);
    _expectCubic(AppMotion.drawer, 0.32, 0.72, 0, 1);
  });

  test('a pressed surface shrinks to 97 percent', () {
    expect(AppMotion.pressedScale, 0.97);
  });

  test('the standard spring is critically damped at 322 stiffness', () {
    final spring = AppMotion.spring;
    expect(spring.mass, 1);
    expect(spring.stiffness, 322);
    expect(spring.damping, closeTo(2 * math.sqrt(322), 1e-9));
  });

  test('the momentum spring is under-damped at 0.8 of critical', () {
    final spring = AppMotion.springMomentum;
    expect(spring.mass, 1);
    expect(spring.stiffness, 322);
    expect(spring.damping, closeTo(2 * 0.8 * math.sqrt(322), 1e-9));
    expect(spring.damping, lessThan(AppMotion.spring.damping));
  });

  testWidgets('reduced follows the platform animation switch', (tester) async {
    final seen = <bool>[];
    for (final disabled in [true, false]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: disabled),
          child: Builder(
            builder: (context) {
              seen.add(AppMotion.reduced(context));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    }
    expect(seen, [true, false]);
  });

  testWidgets('switchFade fades the child with the given animation', (
    tester,
  ) async {
    const animation = AlwaysStoppedAnimation<double>(0.4);
    const child = SizedBox(key: Key('child'));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AppMotion.switchFade(child, animation),
      ),
    );
    final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    expect(fade.opacity, same(animation));
    expect(find.byKey(const Key('child')), findsOneWidget);
  });
}
