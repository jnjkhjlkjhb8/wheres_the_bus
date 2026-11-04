import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/station_picker_sheet.dart';

void main() {
  testWidgets('station picker filters names and returns the selected station', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await StationPickerSheet.show(context, [
                  '台北',
                  '台南',
                  '高雄',
                ]);
              },
              child: const Text('Pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(find.text('台北'), findsOneWidget);
    expect(find.text('高雄'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '台');
    await tester.pump();
    expect(find.text('台北'), findsOneWidget);
    expect(find.text('台南'), findsOneWidget);
    expect(find.text('高雄'), findsNothing);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('台南'), findsNothing);
    await tester.enterText(find.byType(TextField), '台南');
    await tester.pump();
    // The query field also shows '台南'; the list row is the later match.
    await tester.tap(find.text('台南').last);
    await tester.pumpAndSettle();
    expect(selected, '台南');
    expect(find.byType(StationPickerSheet), findsNothing);
  });
}
