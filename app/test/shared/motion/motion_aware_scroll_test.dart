import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/motion_aware_scroll.dart';

void main() {
  late ScrollController controller;

  Future<void> pumpList(WidgetTester tester) async {
    controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: List.generate(
            40,
            (i) => SizedBox(height: 100, child: Text('$i')),
          ),
        ),
      ),
    );
  }

  Future<void> scroll(bool reduced) => controller.jumpOrAnimateTo(
    300,
    reduced: reduced,
    duration: const Duration(milliseconds: 300),
    curve: Curves.linear,
  );

  testWidgets('reduced jumps straight to the offset', (tester) async {
    await pumpList(tester);

    await scroll(true);

    expect(controller.offset, 300);
  });

  testWidgets('not reduced tweens', (tester) async {
    await pumpList(tester);

    final done = scroll(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.offset, inExclusiveRange(0, 300));
    await tester.pumpAndSettle();
    await done;
    expect(controller.offset, 300);
  });
}
