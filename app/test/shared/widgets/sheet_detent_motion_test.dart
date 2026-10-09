import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

Future<SheetController> _pumpSheet(WidgetTester tester) async {
  final controller = SheetController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: SheetViewport(
        child: Sheet(
          controller: controller,
          initialOffset: AppSheetSnap.peek,
          snapGrid: AppSheetSnap.grid,
          decoration: const MaterialSheetDecoration(
            size: SheetSize.stretch,
            color: Colors.white,
          ),
          child: const SizedBox(height: 800),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('animateToDetent travels to the target detent', (tester) async {
    final controller = await _pumpSheet(tester);

    unawaited(controller.animateToDetent(AppSheetSnap.full, reduced: false));
    await tester.pumpAndSettle();

    expect(
      controller.metrics!.offset,
      closeTo(AppSheetSnap.full.resolve(controller.metrics!), 0.5),
    );
  });

  // Reduce-motion used to pass Duration.zero here, which trips smooth_sheets'
  // own `duration > Duration.zero` assert instead of collapsing the travel.
  testWidgets('animateToDetent under reduce-motion still arrives', (
    tester,
  ) async {
    final controller = await _pumpSheet(tester);

    unawaited(controller.animateToDetent(AppSheetSnap.full, reduced: true));
    await tester.pumpAndSettle();

    expect(
      controller.metrics!.offset,
      closeTo(AppSheetSnap.full.resolve(controller.metrics!), 0.5),
    );
  });
}
