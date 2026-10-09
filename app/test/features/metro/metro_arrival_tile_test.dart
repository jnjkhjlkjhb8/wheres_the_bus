import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,

      theme: AppTheme.light,
      home: Scaffold(body: child),
    ),
  );

  testWidgets('metro arrival renders through the shared EtaListTile', (
    tester,
  ) async {
    await pump(
      tester,
      const MetroArrivalTile(
        arrival: MetroArrival(
          line: 'R',
          destination: '淡水',
          estimateSeconds: 245,
        ),
      ),
    );

    // Metro rows go through the shared tile (in its bare variant), not a
    // hand-rolled Row.
    expect(find.byType(EtaListTile), findsOneWidget);
    expect(find.text('往 淡水'), findsOneWidget);
    // The 分/秒 countdown renders through the shared mono time column: 245s
    // reads as 4分05秒 (seconds zero-padded).
    expect(find.text('4'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);
    expect(find.text('秒'), findsOneWidget);
    final minutes = tester.widget<Text>(find.text('4'));
    expect(minutes.style?.fontFamily, 'IBMPlexMono');
    expect(
      minutes.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
    final seconds = tester.widget<Text>(find.text('05'));
    expect(seconds.style?.fontFamily, 'IBMPlexMono');
  });

  testWidgets('a train at zero collapses to 進站中', (tester) async {
    await pump(
      tester,
      const MetroArrivalTile(
        arrival: MetroArrival(
          line: 'BL',
          destination: '南港',
          estimateSeconds: 0,
        ),
      ),
    );

    expect(find.byType(EtaListTile), findsOneWidget);
    expect(find.text('進站中'), findsOneWidget);
  });
}
