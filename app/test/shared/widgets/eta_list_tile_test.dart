import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/crowd_meter.dart';
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
  testWidgets('ETA shapes retain clock, seconds and service wording', (
    tester,
  ) async {
    for (final muted in [false, true]) {
      for (final (status, labels) in <(EtaStatus, List<String>)>[
        (const EtaApproaching(), ['即將進站']),
        (const EtaMinutesSeconds(3, 7), ['3', '07']),
        (const EtaLabel('08:30'), ['08:30']),
        (const EtaLabel('末班已過'), ['末班已過']),
        (const EtaUnknown(), ['—']),
      ]) {
        await pump(tester, EtaValue(status: status, muted: muted));
        for (final text in labels) {
          expect(find.text(text), findsOneWidget);
        }
        if (status is EtaLabel) {
          final rendered = tester.widget<Text>(find.text(status.text));
          expect(
            rendered.style!.color,
            muted
                ? AppTheme.inkTertiary(Brightness.light)
                : status.text.contains(':')
                ? AppTheme.light.colorScheme.onSurface
                : AppTheme.light.colorScheme.onSurfaceVariant,
          );
        }
      }
    }
  });

  testWidgets(
    'bare rows retain custom leading, track and mute crowd information',
    (tester) async {
      var taps = 0;
      for (final bare in [false, true]) {
        for (final muted in [false, true]) {
          await pump(
            tester,
            EtaListTile(
              routeNo: '307',
              destination: '板橋',
              status: const EtaMinutes(5),
              bare: bare,
              muted: muted,
              highlighted: true,
              leading: const Icon(Icons.train),
              direction: '去程',
              destinationStyle: const TextStyle(color: Colors.purple),
              track: const Text('tracking'),
              crowdLevel: CrowdLevel.crowded,
              onTap: () => taps++,
            ),
          );
          expect(find.byIcon(Icons.train), findsOneWidget);
          expect(find.text('去程'), findsOneWidget);
          expect(find.text('tracking'), findsOneWidget);
          expect(
            tester.widget<Text>(find.text('往 板橋')).style!.color,
            Colors.purple,
          );
          expect(
            find.byType(CrowdMeter),
            muted ? findsNothing : findsOneWidget,
          );
          expect(find.byType(Pressable), bare ? findsNothing : findsOneWidget);
          if (!bare) {
            await tester.tap(find.text('去程'));
          }
        }
      }
      expect(taps, 2);
      await pump(
        tester,
        const EtaListTile(
          routeNo: '261',
          destination: 'A',
          status: EtaUnknown(),
          bare: true,
        ),
      );
      expect(find.text('261'), findsOneWidget);
      expect(find.text('tracking'), findsNothing);
    },
  );
}
