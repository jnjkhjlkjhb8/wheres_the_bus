import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_quantity_selector.dart';

void main() {
  testWidgets(
    'quantity bounds stay inert and rapid changes settle at the latest value',
    (
      tester,
    ) async {
      var value = 1;
      var callbacks = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Center(
                  child: AppQuantitySelector(
                    value: value,
                    max: 3,
                    onChanged: (next) => setState(() {
                      value = next;
                      callbacks++;
                    }),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();
      expect(callbacks, 1);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(value, 2);
      expect(find.text('2'), findsOneWidget);
      update(() => value = 3);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(callbacks, 3);
      expect(find.text('3'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.remove_rounded)),
      );
      await tester.pump(const Duration(milliseconds: 110));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(callbacks, 3);
    },
  );

  testWidgets('reduced motion updates the displayed quantity immediately', (
    tester,
  ) async {
    var value = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: StatefulBuilder(
              builder: (context, setState) => Center(
                child: AppQuantitySelector(
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.remove_rounded));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
