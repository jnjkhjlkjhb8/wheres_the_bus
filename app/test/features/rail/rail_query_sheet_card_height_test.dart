import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';

void main() {
  // Switching mode must not resize the card: the sheet sizes to its content,
  // so a taller card shoves everything below it (and the sheet edge) around.
  testWidgets('O/D and train cards are the same height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: Scaffold(
          body: RailQuerySheetContent(onSubmit: (_) {}),
        ),
      ),
    );

    final card = find.byType(AppCard).first;
    final odHeight = tester.getSize(card).height;

    await tester.tap(find.text('車次查詢'));
    await tester.pumpAndSettle();

    expect(tester.getSize(card).height, odHeight);
  });
}
