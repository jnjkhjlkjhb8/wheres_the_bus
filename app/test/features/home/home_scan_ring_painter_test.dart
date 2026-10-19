import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

void main() {
  const center = Offset(150, 200);
  const color = Color(0xFF123456);
  const radius = 100.0;

  Future<RenderObject> pumpRing(
    WidgetTester tester,
    double t, {
    bool still = false,
  }) async {
    final progress = AnimationController(vsync: tester)..value = t;
    addTearDown(progress.dispose);
    final painter = scanRingPainterForTest(
      progress: progress,
      center: center,
      radius: radius,
      color: color,
      still: still,
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomPaint(painter: painter, size: const Size(300, 400)),
      ),
    );
    return tester.renderObject(find.byType(CustomPaint));
  }

  group('painting', () {
    testWidgets('nothing is drawn before the sweep starts', (tester) async {
      expect(await pumpRing(tester, 0), paintsNothing);
    });

    testWidgets('nothing is drawn once the sweep has finished', (tester) async {
      expect(await pumpRing(tester, 1), paintsNothing);
    });

    testWidgets('mid-sweep a wash and a 1.5 px stroke share the centre', (
      tester,
    ) async {
      final eased = AppMotion.easeOut.transform(0.5);
      final alpha = 0.55 * (1 - (eased - 0.1) / (1 - 0.1));
      final ringRadius = 12 + (radius - 12) * eased;

      expect(
        await pumpRing(tester, 0.5),
        paints
          ..circle(x: center.dx, y: center.dy, radius: ringRadius)
          ..circle(
            x: center.dx,
            y: center.dy,
            radius: ringRadius,
            strokeWidth: 1.5,
            style: PaintingStyle.stroke,
            color: color.withValues(alpha: alpha),
          ),
      );
    });

    testWidgets('the first tenth of the fade climbs linearly to the peak', (
      tester,
    ) async {
      const t = 0.01;
      final eased = AppMotion.easeOut.transform(t);
      expect(eased, lessThan(0.1));

      expect(
        await pumpRing(tester, t),
        paints
          ..circle()
          ..circle(
            radius: 12 + (radius - 12) * eased,
            color: color.withValues(alpha: 0.55 * eased / 0.1),
          ),
      );
    });

    testWidgets('the still ring holds its radius and breathes at 35%', (
      tester,
    ) async {
      expect(
        await pumpRing(tester, 0.5, still: true),
        paints
          ..circle(radius: radius)
          ..circle(radius: radius, color: color.withValues(alpha: 0.35)),
      );
    });
  });

  group('wash gradient', () {
    test('fades from a 7% share of the stroke opacity to nothing', () {
      final wash = scanWashForTest(color, 0.5);

      expect(wash.colors, [
        color.withValues(alpha: 0.5 * 0.07),
        color.withValues(alpha: 0),
      ]);
      expect(wash.stops, [0, 0.72]);
    });
  });

  group('shouldRepaint', () {
    final progress = AnimationController(vsync: const TestVSync());
    CustomPainter make({
      Offset at = center,
      double r = radius,
      Color c = color,
      bool still = false,
    }) => scanRingPainterForTest(
      progress: progress,
      center: at,
      radius: r,
      color: c,
      still: still,
    );
    tearDownAll(progress.dispose);

    test('an identical ring is left alone', () {
      expect(make().shouldRepaint(make()), isFalse);
    });

    test('a moved centre repaints', () {
      expect(make().shouldRepaint(make(at: const Offset(151, 200))), isTrue);
    });

    test('a changed radius repaints', () {
      expect(make().shouldRepaint(make(r: 101)), isTrue);
    });

    test('a changed colour repaints', () {
      expect(make().shouldRepaint(make(c: Colors.red)), isTrue);
    });

    test('a switch between sweep and still repaints', () {
      expect(make().shouldRepaint(make(still: true)), isTrue);
    });
  });
}
