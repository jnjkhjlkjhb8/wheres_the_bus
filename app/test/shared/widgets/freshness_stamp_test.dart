import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';

final _zh = lookupAppI18n(const Locale('zh'));

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  testWidgets('renders nothing before the first frame lands', (tester) async {
    await pump(tester, const FreshnessStamp(at: null));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a leading fact survives a null timestamp', (tester) async {
    await pump(tester, const FreshnessStamp(at: null, leading: '30 車位'));
    expect(find.text('30 車位'), findsOneWidget);
  });

  testWidgets('pads the reading to a wall clock', (tester) async {
    await pump(
      tester,
      FreshnessStamp(at: DateTime(2026, 8, 31, 9, 5)),
    );
    expect(find.text('09:05'), findsOneWidget);
  });

  testWidgets('the reading leaves the body face, the label does not', (
    tester,
  ) async {
    await pump(
      tester,
      FreshnessStamp(at: DateTime(2026, 8, 31, 9, 5), leading: '30 車位'),
    );
    final reading = tester.widget<Text>(find.text('09:05'));
    expect(reading.style?.fontFamily, AppTextStyles.timeValue().fontFamily);
    final label = tester.widget<Text>(find.textContaining('30 車位'));
    expect(label.style?.fontFamily, isNot(reading.style?.fontFamily));
  });
  testWidgets('states the leading fact, the label and the reading in order', (
    tester,
  ) async {
    await pump(
      tester,
      FreshnessStamp(at: DateTime(2026, 8, 31, 23, 59), leading: '30 車位'),
    );
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .toList();
    expect(texts, ['30 車位 · ', '${_zh.commonUpdatedAt} ', '23:59']);
  });

  testWidgets('the reading is 12pt in the label colour and the row hugs', (
    tester,
  ) async {
    await pump(tester, FreshnessStamp(at: DateTime(2026, 8, 31, 9, 5)));
    final reading = tester.widget<Text>(find.text('09:05'));
    final label = tester.widget<Text>(find.text('${_zh.commonUpdatedAt} '));
    expect(reading.style?.fontSize, 12);
    expect(reading.style?.color, label.style?.color);
    expect(label.style?.color, isNotNull);
    expect(tester.widget<Row>(find.byType(Row)).mainAxisSize, MainAxisSize.min);
    expect(find.text('·'), findsNothing);
  });

  testWidgets('a bare stamp carries no separator', (tester) async {
    await pump(tester, FreshnessStamp(at: DateTime(2026, 8, 31, 0, 0)));
    expect(find.textContaining('·'), findsNothing);
    expect(find.text('00:00'), findsOneWidget);
  });

  testWidgets('a lone leading fact uses the label colour', (tester) async {
    await pump(tester, const FreshnessStamp(at: null, leading: '30 車位'));
    final label = tester.widget<Text>(find.text('30 車位'));
    expect(label.style?.color, isNotNull);
    expect(find.byType(Row), findsNothing);
  });

  test('hhmm pads each field separately', () {
    expect(FreshnessStamp.hhmm(DateTime(2026, 1, 1, 7, 3)), '07:03');
    expect(FreshnessStamp.hhmm(DateTime(2026, 1, 1, 17, 30)), '17:30');
    expect(FreshnessStamp.hhmm(DateTime(2026, 1, 1, 0, 0)), '00:00');
  });
}
