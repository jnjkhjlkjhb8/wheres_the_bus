import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('dial drags select sectors with reduced motion $reduced', (
      tester,
    ) async {
      var selected = 0;
      var released = 0;
      var items = ['north', 'east', 'south', 'west'];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Center(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return ClockDial(
                      items: items,
                      selectedIndex: selected,
                      onSelected: (index) => setState(() => selected = index),
                      onReleased: () => released++,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(ClockDial));
      final drag = await tester.startGesture(center + const Offset(0, -90));
      await drag.moveTo(center + const Offset(90, 0));
      await tester.pump(const Duration(milliseconds: 20));
      expect(selected, 1);
      await drag.moveTo(center + const Offset(0, 90));
      await tester.pump(const Duration(milliseconds: 20));
      expect(selected, 2);
      await drag.up();
      await tester.pumpAndSettle();
      expect(released, 1);
      update(() {
        items = ['first', 'second', 'third'];
        selected = 0;
      });
      await tester.pumpAndSettle();
      expect(find.text('north'), findsNothing);
      expect(find.text('first'), findsOneWidget);
      expect(tester.takeException(), isNull);
      update(() => selected = 2);
      await tester.pumpAndSettle();
      expect(tester.widget<ClockDial>(find.byType(ClockDial)).selectedIndex, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('an empty dial ignores movement and remains safe to release', (
    tester,
  ) async {
    final changes = <int>[];
    var released = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ClockDial(
              items: const [],
              selectedIndex: -1,
              onSelected: changes.add,
              onReleased: () => released++,
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ClockDial), const Offset(60, 30));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(released, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  const dialSize = 256.0;
  const radius = dialSize / 2 - 24;

  Future<void> pumpDial(
    WidgetTester tester, {
    required List<String> items,
    required int selected,
    ValueChanged<int>? onSelected,
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Center(
            child: ClockDial(
              items: items,
              selectedIndex: selected,
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );

  Finder knob() => find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.constraints == const BoxConstraints.tightFor(width: 48, height: 48),
  );

  Offset knobCentre(WidgetTester tester) =>
      tester.getCenter(knob()) - tester.getTopLeft(find.byType(ClockDial));

  Offset onRing(double theta) => Offset(
    dialSize / 2 + radius * cos(theta),
    dialSize / 2 + radius * sin(theta),
  );

  double sectorAngle(int i, int n) => -pi / 2 + i / n * 2 * pi;

  group('hand and labels', () {
    for (final (n, i) in [(4, 0), (4, 1), (4, 3), (3, 1), (3, 2)]) {
      testWidgets('selection $i of $n sits at its sector', (tester) async {
        await pumpDial(
          tester,
          items: [for (var k = 0; k < n; k++) 'item$k'],
          selected: i,
        );

        final expected = onRing(sectorAngle(i, n));
        expect(knobCentre(tester).dx, closeTo(expected.dx, 1e-6));
        expect(knobCentre(tester).dy, closeTo(expected.dy, 1e-6));

        final hand = tester.widget<Transform>(
          find.byWidgetPredicate(
            (w) => w is Transform && w.alignment == Alignment.topCenter,
          ),
        );
        final rotated = Matrix4.rotationZ(sectorAngle(i, n) - pi / 2);
        for (var k = 0; k < 16; k++) {
          expect(hand.transform.storage[k], closeTo(rotated.storage[k], 1e-9));
        }
        final anchor = tester.widget<Positioned>(
          find.ancestor(
            of: find.byWidget(hand),
            matching: find.byType(Positioned),
          ),
        );
        expect((anchor.left, anchor.top), (dialSize / 2, dialSize / 2));
      });
    }

    testWidgets('labels ring the dial and the chosen one is bold', (
      tester,
    ) async {
      await pumpDial(
        tester,
        items: const ['a', 'b', 'c', 'd', 'e'],
        selected: 2,
      );
      final cs = Theme.of(tester.element(find.byType(ClockDial))).colorScheme;
      final origin = tester.getTopLeft(find.byType(ClockDial));

      for (var k = 0; k < 5; k++) {
        final label = 'abcde'[k];
        final centre = tester.getCenter(find.text(label)) - origin;
        final expected = onRing(sectorAngle(k, 5));
        expect(centre.dx, closeTo(expected.dx, 1e-6), reason: label);
        expect(centre.dy, closeTo(expected.dy, 1e-6), reason: label);
        final style = tester
            .widget<AnimatedDefaultTextStyle>(
              find.byWidgetPredicate(
                (w) =>
                    w is AnimatedDefaultTextStyle &&
                    w.child is Text &&
                    (w.child as Text).data == label,
              ),
            )
            .style;
        expect(
          style.fontWeight,
          k == 2 ? FontWeight.w700 : FontWeight.w500,
          reason: label,
        );
        expect(
          style.color,
          k == 2 ? cs.onPrimary : cs.onSurface,
          reason: label,
        );
      }
    });

    for (final (selected, shown) in [
      (-1, false),
      (0, true),
      (3, true),
      (4, false),
    ]) {
      testWidgets('selection $selected of 4 ${shown ? "shows" : "hides"} '
          'the hand', (tester) async {
        await pumpDial(
          tester,
          items: const ['a', 'b', 'c', 'd'],
          selected: selected,
        );

        expect(knob(), shown ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('an outside selection change snaps the hand there', (
      tester,
    ) async {
      const items = ['a', 'b', 'c', 'd'];
      await pumpDial(tester, items: items, selected: 0);
      await pumpDial(tester, items: items, selected: 1);
      await tester.pump();

      final expected = onRing(sectorAngle(1, 4));
      expect(knobCentre(tester).dx, closeTo(expected.dx, 1e-6));
      expect(knobCentre(tester).dy, closeTo(expected.dy, 1e-6));
    });

    testWidgets('a new item set returns the hand to the selection', (
      tester,
    ) async {
      await pumpDial(tester, items: const ['a', 'b', 'c', 'd'], selected: 2);
      await pumpDial(tester, items: const ['x', 'y', 'z'], selected: 1);
      await tester.pumpAndSettle();

      final expected = onRing(sectorAngle(1, 3));
      expect(knobCentre(tester).dx, closeTo(expected.dx, 0.05));
      expect(knobCentre(tester).dy, closeTo(expected.dy, 0.05));
    });

    testWidgets('a tap picks its sector and buzzes once', (tester) async {
      final picked = <int>[];
      final buzzes = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          buzzes.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpDial(
        tester,
        items: const ['a', 'b', 'c', 'd'],
        selected: 0,
        onSelected: picked.add,
      );
      final origin = tester.getTopLeft(find.byType(ClockDial));

      await tester.tapAt(origin + onRing(sectorAngle(2, 4)));
      await tester.pump();

      expect(picked, [2]);
      expect(
        buzzes.where((c) => c.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      // Tapping the sector already chosen is silent.
      await pumpDial(
        tester,
        items: const ['a', 'b', 'c', 'd'],
        selected: 2,
        onSelected: picked.add,
      );
      await tester.tapAt(origin + onRing(sectorAngle(2, 4)));
      await tester.pump();
      expect(picked, [2]);
      expect(
        buzzes.where((c) => c.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
    });
  });

  group('release momentum', () {
    // A counter-clockwise flick from east to north, then a set swap whose
    // shortest sweep also runs counter-clockwise: the flick's velocity is kept.
    Future<(double, Velocity)> flickThenSwap(
      WidgetTester tester, {
      required int nextSelected,
    }) async {
      await pumpDial(tester, items: const ['a', 'b', 'c', 'd'], selected: 1);
      final origin = tester.getTopLeft(find.byType(ClockDial));
      Offset at(double theta) =>
          origin + Offset(128 + 90 * cos(theta), 128 + 90 * sin(theta));

      final tracker = VelocityTracker.withKind(PointerDeviceKind.touch);
      var t = const Duration(seconds: 1);
      final pointer = TestPointer();
      await tester.sendEventToBinding(pointer.down(at(0), timeStamp: t));
      tracker.addPosition(t, at(0));
      for (var k = 1; k <= 8; k++) {
        t += const Duration(milliseconds: 8);
        final p = at(-pi / 2 * k / 8);
        await tester.sendEventToBinding(pointer.move(p, timeStamp: t));
        tracker.addPosition(t, p);
      }
      await tester.sendEventToBinding(pointer.up(timeStamp: t));
      await tester.pump();
      final velocity = Velocity(
        pixelsPerSecond: tracker.getVelocity().pixelsPerSecond,
      ).clampMagnitude(kMinFlingVelocity, kMaxFlingVelocity);

      await pumpDial(
        tester,
        items: const ['x', 'y', 'z'],
        selected: nextSelected,
      );
      await tester.pump();
      return (-pi / 2, velocity);
    }

    double angularVelocity(Velocity v) {
      final x = 90 * cos(-pi / 2);
      final y = 90 * sin(-pi / 2);
      return (x * v.pixelsPerSecond.dy - y * v.pixelsPerSecond.dx) /
          (x * x + y * y);
    }

    testWidgets('a flick toward the new selection is carried into the sweep', (
      tester,
    ) async {
      final (start, velocity) = await flickThenSwap(tester, nextSelected: 2);
      final omega = angularVelocity(velocity);
      expect(omega, lessThan(0));
      const target = 5 * pi / 6 - 2 * pi;
      final sim = SpringSimulation(AppMotion.spring, start, target, omega);

      await tester.pump(const Duration(milliseconds: 40));

      final expected = onRing(sim.x(0.040));
      expect(knobCentre(tester).dx, closeTo(expected.dx, 0.05));
      expect(knobCentre(tester).dy, closeTo(expected.dy, 0.05));
    });

    testWidgets('a flick away from the new selection is dropped', (
      tester,
    ) async {
      final (start, velocity) = await flickThenSwap(tester, nextSelected: 1);
      expect(angularVelocity(velocity), lessThan(0));
      const target = pi / 6;
      final sim = SpringSimulation(AppMotion.spring, start, target, 0);

      await tester.pump(const Duration(milliseconds: 40));

      final expected = onRing(sim.x(0.040));
      expect(knobCentre(tester).dx, closeTo(expected.dx, 0.05));
      expect(knobCentre(tester).dy, closeTo(expected.dy, 0.05));
    });

    testWidgets('reduced motion jumps straight to the new selection', (
      tester,
    ) async {
      await pumpDial(
        tester,
        items: const ['a', 'b', 'c', 'd'],
        selected: 1,
        reduced: true,
      );
      await pumpDial(
        tester,
        items: const ['x', 'y', 'z'],
        selected: 2,
        reduced: true,
      );
      await tester.pump();

      final expected = onRing(5 * pi / 6);
      expect(knobCentre(tester).dx, closeTo(expected.dx, 1e-6));
      expect(knobCentre(tester).dy, closeTo(expected.dy, 1e-6));
    });
  });
}
