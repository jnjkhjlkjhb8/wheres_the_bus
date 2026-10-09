import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/fare_preference.dart';

// Pinned to zh-TW: `flutter_test` reports an en_US platform locale, and these
// assertions are about the Chinese copy specifically.
Widget wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: child,
);

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_fare_preference');
    await HiveStore.init(initBinding: () async {});
  });

  setUp(() => SettingsRepository.instance.fareType = FareType.full);

  testWidgets('re-renders when the ticket type changes in Settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        FarePreferenceBuilder(
          builder: (context, fareType) =>
              Text(fareType.labelOf(AppI18n.of(context))),
        ),
      ),
    );
    expect(find.text('全票'), findsOneWidget);

    // The write is the only signal — no bloc, no rebuild from above. This is
    // what makes an already-loaded rail or bus screen re-price itself when the
    // rider walks back from Settings.
    SettingsRepository.instance.fareType = FareType.concession;
    await tester.pumpAndSettle();

    expect(find.text('敬老及愛心票'), findsOneWidget);
  });

  testWidgets('names the ticket type beside the price', (tester) async {
    await tester.pumpWidget(
      wrap(
        const FareAmount(
          fare: (price: 32, matched: FareType.concession),
          requested: FareType.concession,
        ),
      ),
    );

    expect(find.text(r'$32'), findsOneWidget);
    expect(find.text('敬老及愛心票'), findsOneWidget);
    expect(find.textContaining('未提供'), findsNothing);
  });

  testWidgets('says so when the price is a full-fare fall back', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const FareAmount(
          // The pair prices no concession fare, so the number is the full one.
          fare: (price: 63, matched: FareType.full),
          requested: FareType.concession,
        ),
      ),
    );

    // The label must read 全票, never 敬老及愛心票 — the whole point of carrying
    // `matched` is that this number is not the discount it was asked for.
    expect(find.text('全票'), findsOneWidget);
    expect(find.text('此區間未提供敬老及愛心票，顯示全票'), findsOneWidget);
  });
}
