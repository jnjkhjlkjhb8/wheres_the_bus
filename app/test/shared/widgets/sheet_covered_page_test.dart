import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

Widget _rootPage(SheetController controller, Listenable insetTicks) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    AnimatedBuilder(
      animation: insetTicks,
      builder: (context, child) {
        final metrics = controller.metrics;
        final viewport = metrics?.viewportSize.height ?? 0;
        final offset = metrics?.offset ?? 0;
        final progress = metrics == null || viewport <= 0
            ? 0.0
            : ((offset - viewport * AppSheetSnap.tallFrac) /
                      (AppSheetSnap.full.resolve(metrics) -
                          viewport * AppSheetSnap.tallFrac))
                  .clamp(0.0, 1.0);
        return Padding(
          padding: EdgeInsets.only(top: 47 * progress),
          child: child,
        );
      },
      child: const SheetDragHandle(),
    ),
    Expanded(child: _list('root')),
  ],
);

Widget _detailPage() => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    const SheetDragHandle(),
    Flexible(child: _list('detail')),
  ],
);

Widget _list(String label) => CustomScrollView(
  physics: const AlwaysScrollableScrollPhysics(),
  slivers: [
    SliverList.builder(
      itemCount: 40,
      itemBuilder: (_, i) => SizedBox(height: 44, child: Text('$label-$i')),
    ),
  ],
);

void main() {
  testWidgets('a detail sheet keeps following the finger down from full', (
    tester,
  ) async {
    final controller = SheetController();
    final navKey = GlobalKey<NavigatorState>();
    final ticks = CurrentPageSheetTicks(
      source: controller,
      isCurrent: () => !(navKey.currentState?.canPop() ?? false),
    );
    addTearDown(ticks.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        // iOS scroll physics, where the bug was reported.
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: MediaQuery(
          // A status bar for the root page's inset to ramp against.
          data: const MediaQueryData(padding: EdgeInsets.only(top: 47)),
          child: SheetViewport(
            child: PagedSheet(
              controller: controller,
              physics: const ClampingSheetPhysics(),
              decoration: const MaterialSheetDecoration(
                size: SheetSize.stretch,
                color: Colors.white,
              ),
              navigator: Navigator(
                key: navKey,
                onGenerateInitialRoutes: (_, _) => [
                  PagedSheetRoute(
                    initialOffset: AppSheetSnap.half,
                    snapGrid: AppSheetSnap.grid,
                    scrollConfiguration: const SheetScrollConfiguration(),
                    builder: (_) => _rootPage(controller, ticks),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drill into a detail page opened at full, the way carriedSheetOffset does
    // when the root sheet is already there.
    unawaited(
      navKey.currentState!.push(
        PagedSheetRoute<void>(
          initialOffset: AppSheetSnap.full,
          snapGrid: AppSheetSnap.grid,
          scrollConfiguration: const SheetScrollConfiguration(),
          builder: (_) => _detailPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.metrics!.offset, controller.metrics!.maxOffset);

    // Pull the detail list down. The root page is still alive behind it with
    // its list attached to the sheet's scroll controller; if that list is
    // re-laid out mid-drag, the sheet snaps back to full under the finger.
    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 16));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final draggedTo = controller.metrics!.offset;
    await gesture.up();
    await tester.pumpAndSettle();

    // 320px of finger travel has to show up as sheet travel, not a spring back
    // to full.
    expect(draggedTo, lessThan(controller.metrics!.maxOffset - 200));
    expect(controller.metrics!.offset, lessThan(controller.metrics!.maxOffset));
  });
}
