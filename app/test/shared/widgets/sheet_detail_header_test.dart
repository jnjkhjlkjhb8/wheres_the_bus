import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/diagnostics/feedback_subject.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';

void main() {
  testWidgets('back and trailing targets sit 4pt from either edge', (
    tester,
  ) async {
    const trailingKey = Key('trailing');
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: SheetDetailHeader(
            title: '臺北轉運站',
            trailing: SizedBox(key: trailingKey, width: 44, height: 44),
          ),
        ),
      ),
    );

    final width = tester.getSize(find.byType(SheetDetailHeader)).width;
    final back = tester.getRect(find.byType(AppBarBackButton));
    final trailing = tester.getRect(find.byKey(trailingKey));

    expect(back.left, 4);
    expect(width - trailing.right, 4);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    // A station sheet is what a report opened over it is about.
    expect(FeedbackSubject.current, '臺北轉運站');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(FeedbackSubject.current, isNull);
  });
}
