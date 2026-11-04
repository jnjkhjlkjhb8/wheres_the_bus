import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';

void main() {
  testWidgets('option row tap target is at least 44x44 (HIG minimum)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: SettingsOptionScreen(
          title: 'Test',
          options: ['A', 'B', 'C'],
          initialSelected: 'A',
        ),
      ),
    );

    for (final label in ['A', 'B', 'C']) {
      final row = find.widgetWithText(Pressable, label);
      expect(row, findsOneWidget);
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(44),
        reason: 'option row tap target must be >= 44 logical px tall',
      );
    }
  });

  Future<void> openPicker(WidgetTester tester, List<String?> results) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, _) => MaterialPage(
            child: Scaffold(
              body: TextButton(
                onPressed: () async =>
                    results.add(await context.push<String>('/pick')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/pick',
          // go_router 18 only animates `builder:` routes under material_ui's
          // MaterialApp; this app (like AppRouter) supplies MaterialPage itself.
          pageBuilder: (_, _) => const MaterialPage(
            child: SettingsOptionScreen(
              title: 'Test',
              options: ['A', 'B'],
              initialSelected: 'A',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  double checkOpacity(WidgetTester tester, String label) => tester
      .widget<Opacity>(
        find.descendant(
          of: find.widgetWithText(Pressable, label),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  testWidgets('option row pads 4px above and below the 36px content', (
    tester,
  ) async {
    await openPicker(tester, []);
    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.widgetWithText(Pressable, 'A'),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.symmetric(vertical: 4));
  });

  testWidgets('picking an option marks it, then pops with its value', (
    tester,
  ) async {
    final results = <String?>[];
    await openPicker(tester, results);
    expect(checkOpacity(tester, 'A'), 1);
    expect(checkOpacity(tester, 'B'), 0);

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(checkOpacity(tester, 'A'), 0);
    expect(checkOpacity(tester, 'B'), 1);

    await tester.pumpAndSettle();
    expect(results, ['B']);
  });

  testWidgets('options sit in the same outlined group as the Settings list', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: SettingsOptionScreen(
          title: 'Test',
          options: ['A', 'B'],
          initialSelected: 'A',
        ),
      ),
    );

    final group = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppCard),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = group.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.boxShadow, isEmpty);
    expect(
      group.padding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    );
  });
}
