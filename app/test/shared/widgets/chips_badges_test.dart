import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_badge.dart';
import 'package:wheres_the_bus/shared/widgets/filter_chip_group.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light,
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: child,
    ),
  ),
);

void main() {
  testWidgets(
    'badge variants preserve labels, data contrast and reduced motion',
    (tester) async {
      for (final reduced in [false, true]) {
        await tester.pumpWidget(
          _app(
            const Row(
              children: [
                AppBadge(label: 'status'),
                AppBadge.outlined(label: 'outline'),
                AppBadge(),
                AppBadge(label: 'dark line', color: Colors.black),
                AppBadge(label: 'light line', color: Colors.white),
              ],
            ),
            reduced: reduced,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('status'), findsOneWidget);
        expect(find.text('outline'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('dark line')).style?.color,
          Colors.white,
        );
        expect(
          tester.widget<Text>(find.text('light line')).style?.color,
          Colors.black,
        );
        final status = find.byWidgetPredicate(
          (widget) => widget is AppBadge && widget.label == 'status',
        );
        expect(
          find.descendant(of: status, matching: find.byType(FadeTransition)),
          reduced ? findsNothing : findsOneWidget,
        );
        final data = find.byWidgetPredicate(
          (widget) => widget is AppBadge && widget.label == 'dark line',
        );
        expect(
          find.descendant(of: data, matching: find.byType(FadeTransition)),
          findsNothing,
        );
      }
    },
  );

  testWidgets('filter chips toggle their own key and keep selected semantics', (
    tester,
  ) async {
    final toggles = <String>[];
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        FilterChipGroup(
          options: const {'rail': 'Rail', 'bus': 'Bus'},
          selected: const {'rail'},
          onToggle: toggles.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Rail')), findsWidgets);
    await tester.tap(find.text('Bus'));
    await tester.pumpAndSettle();
    expect(toggles, ['bus']);
    await tester.pumpWidget(
      _app(
        FilterChipGroup(
          options: const {'rail': 'Rail', 'bus': 'Bus'},
          selected: const {'bus'},
          onToggle: toggles.add,
        ),
        reduced: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rail'));
    await tester.pump();
    expect(toggles, ['bus', 'rail']);
    semantics.dispose();
  });
}
