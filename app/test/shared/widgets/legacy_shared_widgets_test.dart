import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/rail_timetable_view.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/expand_from_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_search_bar.dart';
import 'package:wheres_the_bus/shared/widgets/coming_soon_stop_banner.dart';
import 'package:wheres_the_bus/shared/widgets/leg_chip.dart';
import 'package:wheres_the_bus/shared/widgets/leg_ribbon.dart';
import 'package:wheres_the_bus/shared/widgets/progress_card.dart';
import 'package:wheres_the_bus/shared/widgets/rail_timetable_card.dart';
import 'package:wheres_the_bus/shared/widgets/route_status_card.dart';
import 'package:wheres_the_bus/shared/widgets/search_result_row.dart';
import 'package:wheres_the_bus/shared/widgets/settings_group.dart';
import 'package:wheres_the_bus/shared/widgets/station_timetable_row.dart';

PlanSection section(String mode, {String line = '', String category = ''}) {
  const place = PlanPlace(
    name: '',
    type: '',
    location: PlanPoint(lat: 0, lng: 0),
    time: '',
  );
  return PlanSection(
    type: '',
    travelSummary: const PlanTravelSummary(duration: 0, length: 0),
    departure: place,
    arrival: place,
    intermediateStops: const [],
    transport: PlanTransport(
      mode: mode,
      name: '',
      shortName: line,
      longName: '',
      headsign: '',
      category: category,
      routeColor: '',
    ),
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      theme: AppTheme.light,
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Center(child: SizedBox(width: 500, child: child)),
        ),
      ),
    ),
  );

  testWidgets('search bar forwards input and explicit presentation', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? query;
    var taps = 0;
    await pump(
      tester,
      AppSearchBar(
        controller: controller,
        onChanged: (v) => query = v,
        onTap: () => taps++,
      ),
    );
    final i18n = AppI18n.of(tester.element(find.byType(AppSearchBar)));
    expect(
      tester.widget<SearchBar>(find.byType(SearchBar)).hintText,
      i18n.commonSearch,
    );
    await tester.enterText(find.byType(TextField), '台北');
    await tester.tap(find.byType(TextField));
    expect(query, '台北');
    expect(controller.text, '台北');
    expect(taps, greaterThan(0));
    await pump(
      tester,
      const AppSearchBar(
        hintText: 'station',
        readOnly: true,
        autofocus: true,
        leading: Icon(Icons.train),
      ),
    );
    final search = tester.widget<SearchBar>(find.byType(SearchBar));
    expect(search.hintText, 'station');
    expect(search.readOnly, isTrue);
    expect(search.autoFocus, isTrue);
    expect(find.byIcon(Icons.train), findsOneWidget);
  });

  testWidgets('arrival banner shows optional clock and custom wording', (
    tester,
  ) async {
    await pump(tester, const ComingSoonStopBanner(name: '站名'));
    final i18n = AppI18n.of(tester.element(find.byType(ComingSoonStopBanner)));
    expect(find.text(i18n.etaArrivingSoon), findsOneWidget);
    expect(find.text('站名'), findsOneWidget);
    await pump(
      tester,
      const ComingSoonStopBanner(name: '目的地', label: 'next', time: '12:30'),
    );
    expect(find.text('next'), findsOneWidget);
    expect(find.text('12:30'), findsOneWidget);
    expect(find.text(i18n.etaArrivingSoon), findsNothing);
  });

  testWidgets(
    'settings row toggles from the row and disabled rows stay inert',
    (tester) async {
      bool? changed;
      await pump(
        tester,
        SettingsGroup(
          title: 'Options',
          children: [
            SettingsSwitchRow(
              title: 'Notifications',
              subtitle: 'All routes',
              icon: Icons.notifications,
              value: false,
              onChanged: (v) => changed = v,
            ),
          ],
        ),
      );
      expect(find.text('Options'), findsOneWidget);
      expect(find.text('All routes'), findsOneWidget);
      expect(find.byIcon(Icons.notifications), findsOneWidget);
      await tester.tap(find.text('Notifications'));
      expect(changed, isTrue);
      changed = null;
      await pump(
        tester,
        const SettingsSwitchRow(
          title: 'Disabled',
          value: true,
          onChanged: null,
        ),
      );
      await tester.tap(find.text('Disabled'));
      expect(changed, isNull);
      expect(tester.widget<ListTile>(find.byType(ListTile)).subtitle, isNull);
      expect(tester.widget<ListTile>(find.byType(ListTile)).leading, isNull);
    },
  );

  testWidgets(
    'progress notch clamps to the track while labels remain visible',
    (tester) async {
      for (final progress in [-1.0, 0.5, 2.0]) {
        await pump(
          tester,
          ProgressCard(
            fromStation: 'A',
            toStation: 'B',
            progress: progress,
            vehicleId: 'V1',
          ),
        );
        expect(find.text('A'), findsOneWidget);
        expect(find.text('B'), findsOneWidget);
        expect(find.text('V1'), findsOneWidget);
        final stackWidth = tester
            .getSize(
              find.descendant(
                of: find.byType(ProgressCard),
                matching: find.byType(Stack),
              ),
            )
            .width;
        final notch = tester
            .widgetList<Positioned>(find.byType(Positioned))
            .last;
        final expected =
            (stackWidth * progress.clamp(0.0, 1.0)).clamp(0.0, stackWidth - 4) -
            2;
        expect(notch.left, expected);
      }
    },
  );

  testWidgets(
    'route status preserves times and marker contrast on line colors',
    (tester) async {
      for (final color in [null, Colors.black, Colors.white]) {
        await pump(
          tester,
          RouteStatusCard(
            origin: 'Origin',
            destination: 'Destination',
            departureTime: '08:00',
            arrivalTime: '08:30',
            lineColor: color,
          ),
        );
        for (final label in ['Origin', 'Destination', '08:00', '08:30']) {
          expect(find.text(label), findsOneWidget);
        }
        final dots = tester
            .widgetList<Container>(find.byType(Container))
            .where(
              (c) =>
                  c.decoration is BoxDecoration &&
                  (c.decoration! as BoxDecoration).shape == BoxShape.circle,
            );
        expect(dots, hasLength(2));
        if (color != null) {
          for (final dot in dots) {
            final decoration = dot.decoration! as BoxDecoration;
            expect((decoration.border! as Border).top.color, color);
            expect(
              decoration.color,
              color == Colors.black ? Colors.white : Colors.black,
            );
          }
        }
      }
    },
  );

  testWidgets('ribbon separates legs but omits trailing connector', (
    tester,
  ) async {
    await pump(
      tester,
      const LegRibbon(
        segments: [
          LegRibbonSegment(
            icon: Icon(Icons.directions_walk),
            minutes: '3m',
            color: Colors.red,
          ),
          LegRibbonSegment(icon: Icon(Icons.train), minutes: '8m'),
          LegRibbonSegment(icon: Icon(Icons.bus_alert), minutes: '12m'),
        ],
      ),
    );
    for (final label in ['3m', '8m', '12m']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(Container), findsNWidgets(2));
    final connectors = tester
        .widgetList<Container>(find.byType(Container))
        .toList();
    expect((connectors.first.decoration! as BoxDecoration).color, Colors.red);
    expect(
      (connectors.last.decoration! as BoxDecoration).color,
      Theme.of(
        tester.element(find.byType(LegRibbon)),
      ).colorScheme.outlineVariant,
    );
    await pump(tester, const LegRibbon(segments: []));
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('leg chips select mode icons, line assets and compact duration', (
    tester,
  ) async {
    final cases = [
      (section('WALK'), Icons.directions_walk_rounded),
      (section('subway', line: 'unknown'), Icons.directions_subway),
      (section('bus', line: '307'), Icons.directions_bus_rounded),
      (
        section('rail', category: 'TRA'),
        Icons.directions_transit_filled_rounded,
      ),
    ];
    for (final entry in cases) {
      await pump(
        tester,
        LegChip(section: entry.$1, duration: const Duration(minutes: 12)),
      );
      expect(find.byIcon(entry.$2), findsOneWidget);
      expect(
        find.text(
          AppI18n.of(tester.element(find.byType(LegChip))).minutesTight(12),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('307'), findsNothing);
    for (final mode in ['subway', 'tram']) {
      for (final line in ['BL', 'R', 'G', 'O', 'BR', 'Y']) {
        await pump(
          tester,
          LegChip(
            section: section(mode, line: line.toLowerCase()),
            duration: const Duration(minutes: 65),
          ),
        );
        expect(find.text('1h5m'), findsOneWidget);
        expect(
          (tester.widget<SvgPicture>(find.byType(SvgPicture)).bytesLoader
                  as SvgAssetLoader)
              .assetName,
          'assets/mrt/$line.svg',
        );
      }
    }
    await pump(
      tester,
      LegChip(
        section: section('rail', category: 'HSR'),
        duration: Duration.zero,
      ),
    );
    expect(
      (tester.widget<SvgPicture>(find.byType(SvgPicture)).bytesLoader
              as SvgAssetLoader)
          .assetName,
      'assets/rails/thsr_logo.svg',
    );
    await pump(
      tester,
      LegChip(
        section: section('bus', line: '307'),
        duration: Duration.zero,
      ),
    );
    expect(find.text('307'), findsOneWidget);
  });

  testWidgets('timetable cards format clocks, delays and route identity', (
    tester,
  ) async {
    var taps = 0;
    for (final delayed in [false, true]) {
      await pump(
        tester,
        RailTimetableCard(
          timetable: const RailTimetableView(
            trainNo: '123',
            trainType: '區間',
            originName: 'A',
            destinationName: 'B',
            departureTime: '2026-07-19T08:00:00',
            arrivalTime: '09:30:00',
            travelTime: '90m',
          ),
          delayMinutes: delayed ? 7 : 0,
          onTap: () => taps++,
        ),
      );
      for (final label in ['123', '08:00', '09:30', '90m', 'A → B']) {
        expect(find.text(label), findsOneWidget);
      }
      final i18n = AppI18n.of(tester.element(find.byType(RailTimetableCard)));
      expect(
        find.text(delayed ? i18n.railDelayMinutes(7) : i18n.onTime),
        findsOneWidget,
      );
      await tester.tap(find.text('123'));
    }
    expect(taps, 2);
    await pump(
      tester,
      const StationTimetableRow(
        time: '08:00',
        trainType: '高鐵',
        destination: '左營',
        platform: '1A',
      ),
    );
    expect(find.text('左營'), findsOneWidget);
    expect(find.text('1A'), findsOneWidget);
    await pump(
      tester,
      const StationTimetableRow(
        time: '08:00',
        trainType: '高鐵',
        destination: '左營',
      ),
    );
    expect(find.text('1A'), findsNothing);
  });

  testWidgets(
    'search results show transport identity and suppress place subtitles',
    (tester) async {
      for (final type in AppSearchResultType.values) {
        var taps = 0;
        await pump(
          tester,
          SearchResultRow(
            result: SearchResultViewData(
              type: type,
              uid: 'id',
              title: 'Name',
              subtitle: 'Detail',
            ),
            onTap: () => taps++,
          ),
        );
        expect(find.text('Name'), findsOneWidget);
        expect(
          find.text('Detail'),
          type == AppSearchResultType.place ? findsNothing : findsOneWidget,
        );
        await tester.tap(find.text('Name'));
        expect(taps, 1);
      }
      await tester.pumpWidget(searchResultRowPreview());
      expect(find.byType(SearchResultRow), findsWidgets);
    },
  );

  testWidgets(
    'container transition respects reduced motion and supplied colors',
    (tester) async {
      for (final reduced in [false, true]) {
        await pump(
          tester,
          ExpandFromButton<void>(
            button: (_, open) =>
                TextButton(onPressed: open, child: const Text('Open')),
            screen: (_, close) => const Scaffold(body: Text('Screen')),
            openColor: reduced ? Colors.red : null,
          ),
          reduced: reduced,
        );
        final container = tester.widget<OpenContainer<void>>(
          find.byType(OpenContainer<void>),
        );
        expect(
          container.transitionDuration,
          reduced ? AppMotion.instant : const Duration(milliseconds: 320),
        );
        expect(
          container.openColor,
          reduced ? Colors.red : AppTheme.light.colorScheme.surface,
        );
        expect(container.middleColor, container.openColor);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Screen'), findsOneWidget);
        Navigator.of(tester.element(find.text('Screen'))).pop();
        await tester.pumpAndSettle();
      }
    },
  );
}
