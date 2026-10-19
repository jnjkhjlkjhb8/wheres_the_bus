import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

void main() {
  const safeTop = 59.0;
  const height = 852.0;

  void sizeAsPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(393 * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget wrap(Widget child) => MediaQuery(
    data: const MediaQueryData(
      padding: EdgeInsets.only(top: safeTop),
      viewPadding: EdgeInsets.only(top: safeTop),
    ),
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets('a page sheet stops on the top edge of the floating controls', (
    tester,
  ) async {
    sizeAsPhone(tester);
    final controller = SheetController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        AppSheet(
          controller: controller,
          initialOffset: AppSheetSnap.full,
          child: const SizedBox(height: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final metrics = controller.metrics!;
    // The controls sit at `SafeArea` + `top: AppSheetSnap.fullInset`, so this
    // is their upper edge to the pixel.
    expect(
      metrics.viewportSize.height - metrics.offset,
      safeTop + AppSheetSnap.fullInset,
    );
  });

  testWidgets('the peek and half fractions still measure the whole window', (
    tester,
  ) async {
    sizeAsPhone(tester);
    final controller = SheetController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        AppSheet(
          controller: controller,
          initialOffset: AppSheetSnap.peek,
          child: const SizedBox(height: 2000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.metrics!.viewportSize.height, height);
    expect(controller.metrics!.offset, height * AppSheetSnap.peekFrac);
  });

  test('the full stop and the floating controls share one inset', () {
    expect(AppSheetSnap.fullInset, AppBarMetrics.floatingTop);
    expect(AppBarMetrics.floatingInsets.top, AppBarMetrics.floatingTop);
  });
}
