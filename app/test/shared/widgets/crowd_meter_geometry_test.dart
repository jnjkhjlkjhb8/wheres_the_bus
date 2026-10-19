import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/shared/widgets/crowd_meter.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    CrowdLevel level, {
    double textScale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Center(child: CrowdMeter(level: level))),
      ),
    ),
  );

  Iterable<Container> bars(WidgetTester tester) => tester.widgetList<Container>(
    find.descendant(
      of: find.byType(CrowdMeter),
      matching: find.byType(Container),
    ),
  );

  test('each level fills a fixed number of segments', () {
    expect(CrowdMeter.filledFor(CrowdLevel.comfortable), 1);
    expect(CrowdMeter.filledFor(CrowdLevel.normal), 2);
    expect(CrowdMeter.filledFor(CrowdLevel.crowded), 3);
    expect(CrowdMeter.filledFor(CrowdLevel.unknown), 0);
  });

  test('each level has its own spoken reading, unknown has none', () {
    expect(CrowdMeter.semanticsLabelFor(CrowdLevel.comfortable), '車上舒適');
    expect(CrowdMeter.semanticsLabelFor(CrowdLevel.normal), '車上一般');
    expect(CrowdMeter.semanticsLabelFor(CrowdLevel.crowded), '車上擁擠');
    expect(CrowdMeter.semanticsLabelFor(CrowdLevel.unknown), isNull);
  });

  testWidgets('three bars rise 5, 8, 11 and are 3 wide at one-to-one scale', (
    tester,
  ) async {
    await pump(tester, CrowdLevel.normal);
    final sizes = [
      for (final bar in bars(tester))
        tester.getSize(find.byWidget(bar)),
    ];
    expect(sizes, const [Size(3, 5), Size(3, 8), Size(3, 11)]);
    final radii = [
      for (final bar in bars(tester))
        ((bar.decoration! as BoxDecoration).borderRadius! as BorderRadius)
            .topLeft
            .x,
    ];
    expect(radii, [1, 1, 1]);
  });

  testWidgets('bars sit 2 apart on a shared baseline', (tester) async {
    await pump(tester, CrowdLevel.crowded);
    final finders = [for (final bar in bars(tester)) find.byWidget(bar)];
    expect(finders, hasLength(3));
    final rects = [for (final f in finders) tester.getRect(f)];
    expect(rects[1].left - rects[0].right, 2);
    expect(rects[2].left - rects[1].right, 2);
    expect(rects[0].bottom, rects[1].bottom);
    expect(rects[1].bottom, rects[2].bottom);
    final row = tester.widget<Row>(
      find.descendant(
        of: find.byType(CrowdMeter),
        matching: find.byType(Row),
      ),
    );
    expect(row.mainAxisSize, MainAxisSize.min);
    expect(row.crossAxisAlignment, CrossAxisAlignment.end);
    expect(tester.getSize(find.byType(CrowdMeter)).width, 3 * 3 + 2 * 2);
  });

  testWidgets('the whole meter scales with the text scale', (tester) async {
    await pump(tester, CrowdLevel.comfortable, textScale: 2);
    final sizes = [
      for (final bar in bars(tester))
        tester.getSize(find.byWidget(bar)),
    ];
    expect(sizes, const [Size(6, 10), Size(6, 16), Size(6, 22)]);
    final rects = [
      for (final bar in bars(tester)) tester.getRect(find.byWidget(bar)),
    ];
    expect(rects[1].left - rects[0].right, 4);
    final radius = ((bars(tester).first.decoration! as BoxDecoration)
            .borderRadius! as BorderRadius)
        .topLeft
        .x;
    expect(radius, 2);
  });

  testWidgets('an unknown level builds an empty box', (tester) async {
    await pump(tester, CrowdLevel.unknown);
    expect(tester.getSize(find.byType(CrowdMeter)), Size.zero);
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('車上舒適'), findsNothing);
    handle.dispose();
  });

  testWidgets('filled segments take the level colour from the bottom up', (
    tester,
  ) async {
    await pump(tester, CrowdLevel.normal);
    final scheme = Theme.of(tester.element(find.byType(CrowdMeter))).colorScheme;
    final colors = [
      for (final bar in bars(tester)) (bar.decoration! as BoxDecoration).color,
    ];
    expect(colors, [
      scheme.onSurfaceVariant,
      scheme.onSurfaceVariant,
      scheme.outline,
    ]);
  });

  testWidgets('a comfortable meter fills only its first segment', (
    tester,
  ) async {
    await pump(tester, CrowdLevel.comfortable);
    final scheme = Theme.of(tester.element(find.byType(CrowdMeter))).colorScheme;
    final colors = [
      for (final bar in bars(tester)) (bar.decoration! as BoxDecoration).color,
    ];
    expect(colors, [
      scheme.onSurfaceVariant,
      scheme.outline,
      scheme.outline,
    ]);
  });

  testWidgets('a crowded meter fills all three in full ink', (tester) async {
    await pump(tester, CrowdLevel.crowded);
    final scheme = Theme.of(tester.element(find.byType(CrowdMeter))).colorScheme;
    final colors = [
      for (final bar in bars(tester)) (bar.decoration! as BoxDecoration).color,
    ];
    expect(colors, [scheme.onSurface, scheme.onSurface, scheme.onSurface]);
  });

  testWidgets('the reading is exposed as a labelled node', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, CrowdLevel.comfortable);
    expect(find.bySemanticsLabel('車上舒適'), findsOneWidget);
    handle.dispose();
  });
}
