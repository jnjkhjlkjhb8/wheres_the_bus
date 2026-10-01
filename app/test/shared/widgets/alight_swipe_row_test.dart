import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_swipe_row.dart';

void main() {
  Widget host({required VoidCallback onSwiped}) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          AlightSwipeRow(
            rowKey: 'KKA-1288',
            onSwiped: onSwiped,
            child: const Text('KKA-1288'),
          ),
        ],
      ),
    ),
  );

  testWidgets('a full right-swipe opens the flow and keeps the row', (
    tester,
  ) async {
    var swipes = 0;
    await tester.pumpWidget(host(onSwiped: () => swipes++));

    await tester.drag(find.text('KKA-1288'), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(swipes, 1);
    // Not a dismissal: what the gesture produces is a mode, and the list
    // position the rider is reading has to survive it.
    expect(find.text('KKA-1288'), findsOneWidget);
  });

  testWidgets('a short drag does not open the flow', (tester) async {
    var swipes = 0;
    await tester.pumpWidget(host(onSwiped: () => swipes++));

    // Well under the 0.35 latch: a thumb drifting sideways mid-scroll must not
    // arm a reminder.
    await tester.drag(find.text('KKA-1288'), const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(swipes, 0);
    expect(find.text('KKA-1288'), findsOneWidget);
  });

  testWidgets('a left-swipe does nothing', (tester) async {
    var swipes = 0;
    await tester.pumpWidget(host(onSwiped: () => swipes++));

    await tester.drag(find.text('KKA-1288'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(swipes, 0);
  });
}
