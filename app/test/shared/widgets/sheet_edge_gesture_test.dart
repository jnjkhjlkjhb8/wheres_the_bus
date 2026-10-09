import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

/// The sheet's full-width content, for measuring what the surface actually
/// covers on screen.
const ValueKey<String> _body = ValueKey('sheet-body');

/// Neither edge leaves the page: pulling a sheet past a detent it has no more
/// travel for resists and springs back, at the top as at the bottom.
Widget _harness({
  required SheetController controller,
  SheetOffset initialOffset = AppSheetSnap.peek,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,

  home: AppSheet(
    controller: controller,
    initialOffset: initialOffset,
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetDragHandle(),
        SizedBox(key: _body, height: 400, width: double.infinity),
      ],
    ),
  ),
);

/// Drags [dy] px per step past an edge, holds for [linger], then lifts.
Future<void> _pullPastEdge(
  WidgetTester tester, {
  required double dy,
  required Duration linger,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(SheetDragHandle)),
  );
  for (var i = 0; i < 6; i++) {
    await gesture.moveBy(Offset(0, dy));
    await tester.pump(const Duration(milliseconds: 8));
  }
  await tester.pump(linger);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('holding past either edge never leaves the page', (tester) async {
    for (final (initialOffset, dy) in const [
      (AppSheetSnap.peek, 60.0),
      (AppSheetSnap.full, -60.0),
    ]) {
      final controller = SheetController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _harness(controller: controller, initialOffset: initialOffset),
      );
      await tester.pumpAndSettle();

      // Far longer than any hold a rider would mean: there is nothing to
      // commit to at either end, however deliberate the pull.
      await _pullPastEdge(
        tester,
        dy: dy,
        linger: const Duration(milliseconds: 700),
      );

      expect(find.byType(AppSheet), findsOneWidget);
    }
  });

  testWidgets('the bottom edge gives, resists, and takes the give back', (
    tester,
  ) async {
    final controller = SheetController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controller: controller));
    await tester.pumpAndSettle();

    // Opens at peek, which for AppSheetSnap.grid is also its lowest detent, so
    // every pixel of a downward drag lands as overflow rather than travel.
    final rest = tester.getTopLeft(find.byType(SheetDragHandle)).dy;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SheetDragHandle)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 8));
    }
    final give = tester.getTopLeft(find.byType(SheetDragHandle)).dy - rest;

    expect(give, greaterThan(1), reason: 'the floor gives rather than locks');
    expect(
      give,
      lessThanOrEqualTo(28),
      reason: '360px of pull buys 28px at most — the resistance is the point',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byType(SheetDragHandle)).dy,
      moreOrLessEquals(rest, epsilon: 0.5),
      reason: 'and the sheet takes the give back once the finger is off',
    );
  });

  testWidgets('a sheet at rest is not inset or dimmed', (tester) async {
    final controller = SheetController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _harness(controller: controller, initialOffset: AppSheetSnap.full),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SheetDragHandle)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await tester.pump(const Duration(milliseconds: 700));

    final dims = tester
        .widgetList<Opacity>(
          find.descendant(
            of: find.byType(SheetEdgeGestureDetector),
            matching: find.byType(Opacity),
          ),
        )
        .map((o) => o.opacity);
    expect(
      dims,
      everyElement(1.0),
      reason: 'dimming telegraphs an exit no sheet has any more',
    );

    // A scale give at the top edge shrank the sheet away from both sides of
    // the viewport, leaving a strip of the page showing down each edge.
    expect(
      tester.getRect(find.byKey(_body)).width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      reason: 'the sheet spans the full width, pulled or not',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
