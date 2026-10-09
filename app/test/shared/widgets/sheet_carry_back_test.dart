import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

/// The home sheet's shape: a root list with a detail page pushed over it.
Widget _page(String label) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    const SizedBox(height: 28),
    Flexible(
      child: CustomScrollView(
        slivers: [
          SliverList.builder(
            itemCount: 40,
            itemBuilder: (_, i) =>
                SizedBox(height: 44, child: Text('$label-$i')),
          ),
        ],
      ),
    ),
  ],
);

void main() {
  testWidgets('a page popped from half leaves the sheet at half', (
    tester,
  ) async {
    final controller = SheetController();
    final navKey = GlobalKey<NavigatorState>();
    final carry = CarryBackSnapGrid(controller: controller);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SheetViewport(
          child: PagedSheet(
            controller: controller,
            physics: const ClampingSheetPhysics(),
            decoration: const MaterialSheetDecoration(
              size: SheetSize.stretch,
              color: Colors.white,
            ),
            navigator: Navigator(
              key: navKey,
              observers: [carry],
              onGenerateInitialRoutes: (_, _) => [
                PagedSheetRoute(
                  // The root opens low, the way home's nearby list does.
                  initialOffset: AppSheetSnap.peek,
                  snapGrid: carry,
                  scrollConfiguration: const SheetScrollConfiguration(),
                  builder: (_) => _page('root'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = controller.metrics!.viewportSize.height;
    expect(controller.metrics!.offset, closeTo(viewport * 0.25, 1));

    // Open a stop from the list at the height the sheet already sits at, then
    // pull it up to half — the rider's gesture, on the pushed page.
    unawaited(
      navKey.currentState!.push(
        PagedSheetRoute<void>(
          initialOffset: AppSheetSnap.peek,
          snapGrid: AppSheetSnap.grid,
          scrollConfiguration: const SheetScrollConfiguration(),
          builder: (_) => _page('detail'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(controller.animateTo(AppSheetSnap.half));
    await tester.pumpAndSettle();
    expect(controller.metrics!.offset, closeTo(viewport * 0.5, 1));

    // Back out. Without the carry the root restores its own peek and the sheet
    // drops half a screen under a gesture that only asked to go back.
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(controller.metrics!.offset, closeTo(viewport * 0.5, 1));

    // The carry is spent: a later drag on the root snaps where it is released,
    // not back to the popped page's height.
    unawaited(controller.animateTo(AppSheetSnap.peek));
    await tester.pumpAndSettle();
    expect(controller.metrics!.offset, closeTo(viewport * 0.25, 1));
  });
}
