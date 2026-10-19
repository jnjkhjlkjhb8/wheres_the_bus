import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_swipe_row.dart';

import '../../support/helpers/haptic_log.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Widget child = const Text('row'),
    VoidCallback? onSwiped,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            AlightSwipeRow(
              rowKey: 'k',
              onSwiped: onSwiped ?? () {},
              child: child,
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('only a rightward pull latches, at 35 percent of the width', (
    tester,
  ) async {
    await mount(tester);
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(dismissible.direction, DismissDirection.startToEnd);
    expect(dismissible.dismissThresholds, {DismissDirection.startToEnd: 0.35});
    expect(dismissible.key, const ValueKey('alight-swipe-k'));
  });

  testWidgets('the latch haptic fires just past 35 percent, not just before', (
    tester,
  ) async {
    final haptics = captureHaptics();
    await mount(tester);
    final width = tester.getSize(find.byType(AlightSwipeRow)).width;
    final gesture = await tester.startGesture(tester.getCenter(find.text('row')));
    // The first move only wins the gesture arena; it is not counted as travel.
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(width * 0.345, 0));
    await tester.pump();
    expect(haptics, isEmpty);
    await gesture.moveBy(Offset(width * 0.01, 0));
    await tester.pump();
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the revealed background is an ink bar with a download glyph', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('row')));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    final scheme = Theme.of(tester.element(find.byType(AlightSwipeRow))).colorScheme;
    final background = tester.widget<Container>(
      find.ancestor(
        of: find.byIcon(Icons.download_rounded),
        matching: find.byType(Container),
      ).first,
    );
    expect(background.color, scheme.onSurface);
    expect(background.alignment, AlignmentDirectional.centerStart);
    expect(
      background.padding,
      const EdgeInsets.symmetric(horizontal: AppTheme.space20),
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.download_rounded));
    expect(icon.size, 20);
    expect(icon.color, scheme.surface);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a bare divider is lifted to a 44 point target and centred', (
    tester,
  ) async {
    await mount(tester, child: const SizedBox(width: 30, height: 5));
    expect(tester.getSize(find.byType(AlightSwipeRow)).height, 44);
    final child = tester.getCenter(find.byType(SizedBox).last);
    expect(child.dx, 400);
  });

  testWidgets('a taller child keeps its own height', (tester) async {
    await mount(tester, child: const SizedBox(width: 30, height: 80));
    expect(tester.getSize(find.byType(AlightSwipeRow)).height, 80);
  });

  testWidgets('a latched swipe reports once and the row stays', (tester) async {
    var swipes = 0;
    await mount(tester, onSwiped: () => swipes++);
    await tester.drag(find.text('row'), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(swipes, 1);
    expect(find.text('row'), findsOneWidget);
  });
}
