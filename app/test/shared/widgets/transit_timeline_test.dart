import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

void main() {
  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 300, height: 60, child: child),
        ),
      ),
    ),
  );

  testWidgets(
    'timeline ends, travelled nodes and the selected ring retain their shapes',
    (tester) async {
      final colors = AppTheme.light.colorScheme;
      for (final kind in TimelineNodeKind.values) {
        for (final travelled in [false, true]) {
          for (final dimmed in [false, true]) {
            await mount(
              tester,
              TimelineSpine(
                kind: kind,
                travelledAbove: travelled,
                travelledBelow: !travelled,
                dimmed: dimmed,
                lineAbove: travelled,
                lineBelow: !travelled,
              ),
            );
            final dimension = switch (kind) {
              TimelineNodeKind.intermediate => 9.0,
              TimelineNodeKind.terminus => 11.0,
              TimelineNodeKind.emphasis => 13.0,
            };
            final node = tester.widget<Container>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is Container &&
                    widget.constraints?.maxWidth == dimension &&
                    widget.decoration is BoxDecoration,
              ),
            );
            final appearance = node.decoration! as BoxDecoration;
            final ink = dimmed
                ? AppTheme.inkTertiary(Brightness.light)
                : colors.onSurface;
            switch (kind) {
              case TimelineNodeKind.terminus:
                expect(appearance.color, ink);
                expect(appearance.borderRadius, BorderRadius.circular(2));
              case TimelineNodeKind.emphasis:
                expect(appearance.color, colors.surface);
                expect((appearance.border! as Border).top.width, 3);
              case TimelineNodeKind.intermediate:
                expect(
                  appearance.color,
                  travelled && !dimmed ? ink : colors.surface,
                );
            }
          }
        }
      }
    },
  );

  testWidgets('stop tags preserve solid and outlined contrast', (tester) async {
    final colors = AppTheme.light.colorScheme;
    for (final solid in [false, true]) {
      await mount(tester, TimelineStopTag('下車站', solid: solid));
      final text = tester.widget<Text>(find.text('下車站'));
      expect(
        text.style!.color,
        solid ? colors.surface : colors.onSurfaceVariant,
      );
      final tag = tester.widget<Container>(
        find.descendant(
          of: find.byType(TimelineStopTag),
          matching: find.byType(Container),
        ),
      );
      final appearance = tag.decoration! as BoxDecoration;
      expect(appearance.color, solid ? colors.onSurface : Colors.transparent);
      expect(appearance.border, solid ? isNull : isNotNull);
    }
  });

  testWidgets(
    'a vehicle marker includes its plate and delay in one accessible label',
    (tester) async {
      final semantics = tester.ensureSemantics();
      for (final alert in [false, true]) {
        await mount(
          tester,
          TimelineVehicleMarker(
            semanticLabel: '公車在這',
            label: 'ABC-123',
            trailing: '延誤 5 分',
            trailingIsAlert: alert,
            badge: Icons.airline_seat_recline_extra_rounded,
          ),
        );
        expect(find.text('ABC-123'), findsOneWidget);
        expect(find.bySemanticsLabel('公車在這，ABC-123，延誤 5 分'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('延誤 5 分')).style!.color,
          alert
              ? AppTheme.trainDelay
              : AppTheme.light.colorScheme.onSurfaceVariant,
        );
      }
      await mount(tester, const TimelineVehicleMarker(semanticLabel: '列車在此'));
      expect(find.bySemanticsLabel('列車在此'), findsOneWidget);
      expect(find.text('ABC-123'), findsNothing);
      semantics.dispose();
    },
  );
}
