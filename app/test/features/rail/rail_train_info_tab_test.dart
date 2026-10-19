import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _stops = [
  RailTrainStop(name: '臺北', arrive: '08:00:00', depart: '08:02:00'),
  RailTrainStop(name: '臺中', arrive: '09:30:00', depart: '09:32:00'),
  RailTrainStop(name: '高雄', arrive: '11:00:00', depart: ''),
];

const _full = RailFareQuote.tra(
  fares: [TraFare(ticketType: '成自', price: 843)],
  trainType: '自強',
);
const _segment = RailFareQuote.tra(
  fares: [TraFare(ticketType: '成自', price: 375)],
  trainType: '自強',
);

void main() {
  final i18n = lookupAppI18n(const Locale('zh'));

  Future<void> show(
    WidgetTester tester, {
    String? origin,
    String? dest,
    RailFareQuote? full,
    RailFareQuote? user,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: RailTrainInfoTab(
            type: '自強',
            trainNo: '123',
            stops: _stops,
            fullFare: full,
            userFare: user,
            userOrigin: origin,
            userDest: dest,
          ),
        ),
      ),
    );
  }

  Finder pair(String a, String b) => find.byWidgetPredicate(
    (w) => w is Row && _rowTexts(w) == [a, '→', b].join('|'),
  );

  testWidgets('without a searched segment the headline is the full run', (
    tester,
  ) async {
    await show(tester);

    expect(pair('臺北', '高雄'), findsOneWidget);
    expect(find.text('08:02'), findsOneWidget);
    expect(find.text('11:00'), findsOneWidget);
    expect(find.text(i18n.railFullRun('臺北', '高雄')), findsNothing);
  });

  testWidgets('an unknown destination keeps the full run as headline', (
    tester,
  ) async {
    await show(tester, origin: '臺中', dest: '不存在');

    expect(pair('臺北', '高雄'), findsOneWidget);
    expect(find.text(i18n.railFullRun('臺北', '高雄')), findsNothing);
  });

  testWidgets('a partial segment leads and names the full run beneath', (
    tester,
  ) async {
    await show(tester, origin: '臺中', dest: '高雄');

    expect(pair('臺中', '高雄'), findsOneWidget);
    expect(find.text('09:32'), findsOneWidget);
    expect(find.text(i18n.railFullRun('臺北', '高雄')), findsOneWidget);
  });

  for (final (origin, dest) in [('臺北', '臺中'), ('臺中', '高雄')]) {
    testWidgets('$origin→$dest is not the full run', (tester) async {
      await show(tester, origin: origin, dest: dest);

      expect(find.text(i18n.railFullRun('臺北', '高雄')), findsOneWidget);
    });
  }

  testWidgets('searching the whole run adds no full-run caption', (
    tester,
  ) async {
    await show(tester, origin: '臺北', dest: '高雄');

    expect(find.text(i18n.railFullRun('臺北', '高雄')), findsNothing);
  });

  testWidgets('no fare quote at all hides the fare section', (tester) async {
    await show(tester);

    expect(find.text(i18n.railFareInfo), findsNothing);
  });

  for (final (name, full, user) in [
    ('full only', _full, null),
    ('segment only', null, _segment),
  ]) {
    testWidgets('a $name quote still shows the fare section', (tester) async {
      await show(tester, origin: '臺中', dest: '高雄', full: full, user: user);

      expect(find.text(i18n.railFareInfo), findsOneWidget);
    });
  }

  testWidgets('a priced segment is labelled by its stops, full run second', (
    tester,
  ) async {
    await show(tester, origin: '臺中', dest: '高雄', full: _full, user: _segment);

    expect(find.text('臺中 → 高雄'), findsOneWidget);
    expect(
      find.text('${i18n.railFullRunInline('臺北', '高雄')}\$843'),
      findsOneWidget,
    );
  });

  testWidgets('with no segment quote the full run labels the fare', (
    tester,
  ) async {
    await show(tester, origin: '臺中', dest: '高雄', full: _full);

    expect(find.text(i18n.railRunPair('臺北', '高雄')), findsOneWidget);
    expect(find.text(i18n.railNoFareForPair('臺中', '高雄')), findsOneWidget);
  });

  testWidgets('a segment quote without a located segment is not used', (
    tester,
  ) async {
    await show(tester, full: _full, user: _segment);

    expect(find.text(i18n.railRunPair('臺北', '高雄')), findsOneWidget);
    expect(find.text('臺中 → 高雄'), findsNothing);
  });
}

String _rowTexts(Row row) => [
  for (final c in row.children)
    if (c is Text) c.data,
].join('|');
