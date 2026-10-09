import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';

void main() {
  testWidgets('thumb stays centred on the selected label', (tester) async {
    const days = {0: '一', 1: '二', 2: '三', 3: '四', 4: '五', 5: '六', 6: '日'};

    for (final selected in days.keys) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 402,
                child: AppSlidingSegment<int>(
                  options: days,
                  value: selected,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final thumb = tester.getRect(
        find.descendant(
          of: find.byType(Positioned),
          matching: find.byType(Container),
        ),
      );
      final label = tester.getRect(find.text(days[selected]!));
      expect(
        thumb.center.dx,
        moreOrLessEquals(label.center.dx, epsilon: 0.5),
        reason: 'thumb drifted off option $selected',
      );
    }
  });

  group('drag', () {
    const options = {0: '去程', 1: '返程'};

    // The control is 200 wide, centred in the 800x600 test view, so the track
    // runs 300..500 with 4px of padding: two 96px pills starting at x=304.
    Future<int?> pumpAndDrag(
      WidgetTester tester, {
      required double from,
      required double by,
    }) async {
      int? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: AppSlidingSegment<int>(
                  options: options,
                  value: 0,
                  onChanged: (v) => changed = v,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(Offset(from, 300));
      // Several steps rather than one jump, so the drag reads as tracking a
      // finger rather than a teleport.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(Offset(by / 4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      return changed;
    }

    testWidgets('dragging the thumb moves the selection', (tester) async {
      expect(await pumpAndDrag(tester, from: 350, by: 96), 1);
    });

    testWidgets('dragging off the thumb changes nothing', (tester) async {
      // Starts on the second pill, which is not the thumb: only the thumb is
      // draggable, so this is a cancelled tap and not a selection.
      expect(await pumpAndDrag(tester, from: 450, by: -96), isNull);
    });

    testWidgets('a flick past the end stays inside the range', (tester) async {
      expect(await pumpAndDrag(tester, from: 350, by: 400), 1);
    });
  });
}
