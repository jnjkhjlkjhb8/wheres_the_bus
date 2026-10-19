import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/widgets/wheel.dart';

void main() {
  const stops = [
    TimelineStop(uid: '0', name: 'A'),
    TimelineStop(uid: '1', name: 'B'),
    TimelineStop(uid: '2', name: 'C'),
  ];
  Offset point(double angle) =>
      Offset(125 + 100 * cos(angle), 125 + 100 * sin(angle));
  GestureDetector detector(WidgetTester tester) =>
      tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(Wheel),
          matching: find.byType(GestureDetector),
        ),
      );
  void start(WidgetTester tester, double angle) => detector(tester).onPanStart!(
    DragStartDetails(localPosition: point(angle)),
  );
  void update(WidgetTester tester, double angle) =>
      detector(tester).onPanUpdate!(
        DragUpdateDetails(
          localPosition: point(angle),
          globalPosition: point(angle),
        ),
      );

  testWidgets('rotations select one station and clamp at each end', (
    tester,
  ) async {
    final selected = <int>[];
    Future<void> pump(int index, {ThemeData? theme}) => tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Wheel(
            stops: stops,
            stationOffsets: const [0, 100, 200],
            selectedIndex: index,
            onStationSelected: selected.add,
          ),
        ),
      ),
    );
    await pump(0);
    start(tester, 0);
    update(tester, pi / 2);
    expect(selected, isEmpty);
    update(tester, pi);
    expect(selected, [1]);
    detector(tester).onPanEnd!(DragEndDetails());
    start(tester, pi);
    update(tester, -pi / 2);
    update(tester, 0);
    expect(selected, [1, 2]);
    start(tester, 0);
    update(tester, pi / 2);
    update(tester, pi);
    expect(selected, [1, 2]);
    await pump(1);
    start(tester, 0);
    update(tester, -pi / 2);
    update(tester, -pi);
    expect(selected, [1, 2, 0]);
    start(tester, 0);
    update(tester, -pi / 2);
    update(tester, -pi);
    expect(selected, [1, 2, 0]);
    await pump(0, theme: ThemeData.dark());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial rotation scrolls between stations then snaps on release',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Future<void> pump(int index, {required bool reduced}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(disableAnimations: reduced),
                  child: Column(
                    children: [
                      Wheel(
                        stops: stops,
                        stationOffsets: const [0, 100, 200],
                        selectedIndex: index,
                        onStationSelected: (_) {},
                        scrollController: controller,
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: controller,
                          itemExtent: 100,
                          itemCount: 10,
                          itemBuilder: (_, i) => Text('$i'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
      await pump(0, reduced: false);
      start(tester, 0);
      update(tester, pi / 6);
      expect(controller.offset, closeTo(25, 1e-9));
      detector(tester).onPanEnd!(DragEndDetails());
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      await pump(1, reduced: true);
      start(tester, 0);
      update(tester, -pi / 6);
      expect(controller.offset, closeTo(75, 1e-9));
      detector(tester).onPanEnd!(DragEndDetails());
      expect(controller.offset, 100);
      await pump(0, reduced: true);
      start(tester, 0);
      update(tester, -pi / 6);
      expect(controller.offset, 0);
      await pump(2, reduced: true);
      start(tester, 0);
      update(tester, pi / 6);
      expect(controller.offset, 200);
    },
  );

  testWidgets('a drag across the +-pi seam turns the short way round', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Column(
              children: [
                Wheel(
                  stops: stops,
                  stationOffsets: const [0, 100, 200],
                  selectedIndex: 1,
                  onStationSelected: (_) {},
                  scrollController: controller,
                ),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: 100,
                    itemCount: 10,
                    itemBuilder: (_, i) => Text('$i'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 0.2 rad forward across the seam: a tenth of the way to the next stop.
    start(tester, pi - 0.1);
    update(tester, -pi + 0.1);
    const progress = 0.2 / (2 * pi / 3);
    expect(controller.offset, closeTo(100 + 100 * progress, 1e-6));

    // And 0.2 rad backward across it.
    start(tester, -pi + 0.1);
    update(tester, pi - 0.1);
    expect(controller.offset, closeTo(100 - 100 * progress, 1e-6));
  });

  testWidgets('the dial is 250 square and paints its two circles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(
            surface: Color(0xFF112233),
            surfaceContainerHighest: Color(0xFF445566),
          ),
        ),
        home: const Scaffold(
          body: Wheel(
            stops: stops,
            stationOffsets: [0, 100, 200],
            selectedIndex: 0,
            onStationSelected: _ignore,
          ),
        ),
      ),
    );

    final dial = find.descendant(
      of: find.byType(Wheel),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(dial.last), const Size(250, 250));
    expect(
      tester.renderObject(dial.last),
      paints
        ..circle(x: 125, y: 125, radius: 125, color: const Color(0xFF445566))
        ..circle(x: 125, y: 125, radius: 50, color: const Color(0xFF112233)),
    );
  });

  testWidgets('the dial repaints when either colour changes', (tester) async {
    Future<CustomPainter> painterFor(Color ring, Color center) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.light(
              surface: center,
              surfaceContainerHighest: ring,
            ),
          ),
          home: const Scaffold(
            body: Wheel(
              stops: stops,
              stationOffsets: [0, 100, 200],
              selectedIndex: 0,
              onStationSelected: _ignore,
            ),
          ),
        ),
      );
      // The theme change animates; read the painter once it has settled.
      await tester.pumpAndSettle();
      final paint = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byType(Wheel),
              matching: find.byType(CustomPaint),
            )
            .last,
      );
      return paint.painter!;
    }

    const a = Color(0xFF111111);
    const b = Color(0xFF222222);
    final base = await painterFor(a, a);
    final sameColours = await painterFor(a, a);
    final ringChanged = await painterFor(b, a);
    final centerChanged = await painterFor(a, b);
    final bothChanged = await painterFor(b, b);

    expect(base.shouldRepaint(sameColours), isFalse);
    expect(base.shouldRepaint(ringChanged), isTrue);
    expect(base.shouldRepaint(centerChanged), isTrue);
    expect(base.shouldRepaint(bothChanged), isTrue);
  });
}

void _ignore(int _) {}
