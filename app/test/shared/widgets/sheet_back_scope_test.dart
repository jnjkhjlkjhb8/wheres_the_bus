import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

import '../../support/helpers/i18n.dart';

Future<SheetController> _pump(WidgetTester tester, SheetOffset at) async {
  final controller = SheetController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: const Text('under'),
      builder: (context, home) => home!,
      routes: {
        '/screen': (_) => SheetBackScope(
          controller: controller,
          child: Scaffold(
            body: SheetViewport(
              child: Sheet(
                controller: controller,
                initialOffset: at,
                snapGrid: AppSheetSnap.grid,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      },
    ),
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(navigator.pushNamed('/screen'));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('back from full settles to half before leaving', (tester) async {
    final controller = await _pump(tester, AppSheetSnap.full);
    final viewport = controller.metrics!.viewportSize.height;

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SheetBackScope), findsOneWidget);
    expect(controller.metrics!.offset, closeTo(viewport * 0.5, 1));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SheetBackScope), findsNothing);
  });

  testWidgets('back from half leaves at once', (tester) async {
    await _pump(tester, AppSheetSnap.half);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SheetBackScope), findsNothing);
  });

  // A pixel of slack absorbs the snap landing a hair above half; one pixel
  // past that is a raised sheet.
  for (final (above, leaves) in [(1.0, true), (2.0, false)]) {
    testWidgets('back ${leaves ? 'leaves' : 'settles'} $above px above half', (
      tester,
    ) async {
      final controller = await _pump(tester, AppSheetSnap.half);
      final half = controller.metrics!.viewportSize.height * 0.5;
      // Snap points hold a settled sheet, so a sub-detent offset only exists
      // while a finger is still dragging it.
      final finger = await tester.startGesture(
        Offset(400, controller.metrics!.viewportSize.height * 0.75),
      );
      await finger.moveBy(const Offset(0, -100));
      await tester.pump();
      await finger.moveBy(Offset(0, 100 - above));
      await tester.pump();
      expect(controller.metrics!.offset, closeTo(half + above, 0.01));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byType(SheetBackScope),
        leaves ? findsNothing : findsOneWidget,
      );
      await finger.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('the drag handle stays visible on the sheet surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(const Scaffold(body: SheetDragHandle())),
    );

    final scheme = Theme.of(
      tester.element(find.byType(SheetDragHandle)),
    ).colorScheme;
    final handle = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere((c) => c.constraints?.maxWidth == 32);
    expect(
      (handle.decoration! as BoxDecoration).color,
      scheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
  });
}
