import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
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

  const arriving = ArrivalDisplay(
    label: '307',
    destination: '板橋',
    status: EtaArriving(),
    rank: 0,
  );

  testWidgets('renders label, destination, and status', (tester) async {
    await pump(
      tester,
      const EtaListTile(
        routeNo: '307',
        destination: '板橋',
        status: EtaArriving(),
      ),
    );

    expect(find.text('307'), findsOneWidget);
    expect(find.text('往 板橋'), findsOneWidget);
    expect(find.text('進站中'), findsOneWidget);
  });

  testWidgets('fromDisplay renders the ArrivalDisplay contract', (
    tester,
  ) async {
    await pump(tester, EtaListTile.fromDisplay(arriving));

    expect(find.text('307'), findsOneWidget);
    expect(find.text('往 板橋'), findsOneWidget);
    expect(find.text('進站中'), findsOneWidget);
  });

  testWidgets('marks the last bus of the day, and only when confirmed', (
    tester,
  ) async {
    await pump(
      tester,
      EtaListTile.fromDisplay(
        const ArrivalDisplay(
          label: '9023',
          destination: '羅東',
          status: EtaMinutes(8),
          rank: 10,
          isLastBus: true,
        ),
      ),
    );
    expect(find.text('末班車'), findsOneWidget);

    await pump(tester, EtaListTile.fromDisplay(arriving));
    expect(find.text('末班車'), findsNothing);
  });

  testWidgets('time value uses the mono font (tabular figures)', (
    tester,
  ) async {
    await pump(
      tester,
      const EtaListTile(
        routeNo: '桃園106',
        destination: '中壢火車站',
        status: EtaMinutes(5),
      ),
    );

    final minutes = tester.widget<Text>(find.text('5'));
    expect(minutes.style?.fontFamily, 'IBMPlexMono');
    expect(
      minutes.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('highlight applies to the rank-0 row only', (tester) async {
    await pump(
      tester,
      Column(
        children: [
          EtaListTile.fromDisplay(arriving, highlighted: true),
          EtaListTile.fromDisplay(
            const ArrivalDisplay(
              label: '261',
              destination: '銘傳大學',
              status: EtaMinutes(5),
              rank: 5,
            ),
          ),
        ],
      ),
    );

    // Exactly one row draws the surface-highlight background; the plain row
    // draws no decoration.
    final highlighted = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final decoration = w.decoration;
      return decoration is BoxDecoration &&
          decoration.color == AppTheme.surfaceHighlightLight;
    });
    expect(highlighted, findsOneWidget);
  });
}
