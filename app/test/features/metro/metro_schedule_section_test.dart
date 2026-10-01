import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  group('metroStationName', () {
    test('resolves a plain code', () {
      expect(metroStationName('R02'), '象山');
      expect(metroStationName('R28'), '淡水');
    });

    test('resolves each component of an interchange id', () {
      // 台北車站 is stored as the combined id `BL12_R10`; TDX reports
      // destinations as single codes, so both halves must resolve.
      expect(metroStationName('BL12'), '台北車站');
      expect(metroStationName('R10'), '台北車站');
    });

    test('resolves branch-line codes', () {
      expect(metroStationName('R22A'), '新北投');
      expect(metroStationName('G03A'), '小碧潭');
    });

    test('returns null outside the TRTC network', () {
      // KRTC codes reach this lookup only if a system filter is missing
      // upstream; a null keeps the raw code visible instead of inventing a
      // Taipei station name for a Kaohsiung train.
      expect(metroStationName('RK1'), isNull);
      expect(metroStationName('A12'), isNull);
    });
  });

  group('normalizeServiceTime', () {
    test('maps past-midnight hours onto the 24-hour clock', () {
      expect(normalizeServiceTime('24:25'), '00:25');
      expect(normalizeServiceTime('25:10'), '01:10');
    });

    test('leaves ordinary times untouched', () {
      expect(normalizeServiceTime('06:02'), '06:02');
      expect(normalizeServiceTime('00:34'), '00:34');
    });

    test('leaves unparseable values untouched', () {
      expect(normalizeServiceTime(''), '');
      expect(normalizeServiceTime('--'), '--');
    });
  });

  group('metroScheduleFrom', () {
    test('resolves destination codes to station names', () {
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'R02',
          firstTime: '06:02',
          lastTime: '00:34',
        ),
      ]);
      expect(rows.single.destination, '象山');
    });

    test('keeps the raw code when it is outside the station list', () {
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'ZZ9',
          firstTime: '06:00',
          lastTime: '23:00',
        ),
      ]);
      expect(rows.single.destination, 'ZZ9');
    });

    test('collapses service-day duplicates of the same times', () {
      // TDX splits one destination across weekday bitmasks; identical times
      // under different masks are the same fact repeated.
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'R28',
          firstTime: '06:07',
          lastTime: '00:42',
        ),
        MetroScheduleEntry(
          line: 'R',
          destination: 'R28',
          firstTime: '06:07',
          lastTime: '00:42',
        ),
      ]);
      expect(rows, hasLength(1));
    });

    test('keeps rows that differ in either time', () {
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'R28',
          firstTime: '06:07',
          lastTime: '00:42',
        ),
        MetroScheduleEntry(
          line: 'R',
          destination: 'R28',
          firstTime: '06:07',
          lastTime: '00:50',
        ),
      ]);
      expect(rows, hasLength(2));
    });

    test('normalises past-midnight times', () {
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'R02',
          firstTime: '06:05',
          lastTime: '24:25',
        ),
      ]);
      expect(rows.single.lastTime, '00:25');
    });

    test('orders by line then destination so groups match the header', () {
      final rows = metroScheduleFrom(const [
        MetroScheduleEntry(
          line: 'R',
          destination: 'R28',
          firstTime: '06:00',
          lastTime: '00:35',
        ),
        MetroScheduleEntry(
          line: 'BL',
          destination: 'BL23',
          firstTime: '06:00',
          lastTime: '00:45',
        ),
        MetroScheduleEntry(
          line: 'R',
          destination: 'R02',
          firstTime: '06:00',
          lastTime: '00:41',
        ),
        MetroScheduleEntry(
          line: 'BL',
          destination: 'BL01',
          firstTime: '06:00',
          lastTime: '00:45',
        ),
      ]);
      expect(
        rows.map((r) => r.destination),
        ['頂埔', '南港展覽館', '象山', '淡水'],
      );
    });
  });

  group('MetroScheduleSection', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    );

    testWidgets('writes 首班/末班 once as column headers, not per row', (
      tester,
    ) async {
      await pump(
        tester,
        const MetroScheduleSection(
          schedule: [
            MetroSchedule(
              line: 'R',
              destination: '象山',
              firstTime: '06:02',
              lastTime: '00:34',
            ),
            MetroSchedule(
              line: 'R',
              destination: '淡水',
              firstTime: '06:07',
              lastTime: '00:42',
            ),
          ],
        ),
      );

      expect(find.text('首班'), findsOneWidget);
      expect(find.text('末班'), findsOneWidget);
      expect(find.text('06:02'), findsOneWidget);
      expect(find.text('00:42'), findsOneWidget);
    });

    testWidgets('a single-line station carries no line grouping', (
      tester,
    ) async {
      await pump(
        tester,
        const MetroScheduleSection(
          schedule: [
            MetroSchedule(
              line: 'R',
              destination: '象山',
              firstTime: '06:02',
              lastTime: '00:34',
            ),
          ],
        ),
      );

      // The sheet header already names the line; repeating it here would be
      // noise.
      expect(find.text('淡水信義線'), findsNothing);
    });

    testWidgets('an interchange groups its rows under each line', (
      tester,
    ) async {
      await pump(
        tester,
        const MetroScheduleSection(
          schedule: [
            MetroSchedule(
              line: 'BL',
              destination: '頂埔',
              firstTime: '06:00',
              lastTime: '00:45',
            ),
            MetroSchedule(
              line: 'R',
              destination: '象山',
              firstTime: '06:00',
              lastTime: '00:41',
            ),
          ],
        ),
      );

      expect(find.text('板南線'), findsOneWidget);
      expect(find.text('淡水信義線'), findsOneWidget);
    });

    testWidgets('empty schedule keeps the section title and says so', (
      tester,
    ) async {
      await pump(tester, const MetroScheduleSection(schedule: []));

      expect(find.text('首末班車'), findsOneWidget);
      expect(find.text('暫無首末班車資料'), findsOneWidget);
      // No column headers over an empty table.
      expect(find.text('首班'), findsNothing);
    });

    testWidgets('loading shows skeleton rows, not a spinner', (tester) async {
      await pump(
        tester,
        const MetroScheduleSection(schedule: [], loading: true),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('暫無首末班車資料'), findsNothing);
    });

    testWidgets('the loading table lands on the loaded table geometry', (
      tester,
    ) async {
      await pump(
        tester,
        const MetroScheduleSection(schedule: [], loading: true),
      );
      final loadingHeader = tester.getRect(find.text('首班'));
      final loadingSize = tester.getSize(find.byType(MetroScheduleSection));

      await pump(
        tester,
        const MetroScheduleSection(
          schedule: [
            MetroSchedule(
              line: 'R',
              destination: '象山',
              firstTime: '06:02',
              lastTime: '00:34',
            ),
            MetroSchedule(
              line: 'R',
              destination: '淡水',
              firstTime: '06:07',
              lastTime: '00:42',
            ),
          ],
        ),
      );

      expect(tester.getRect(find.text('首班')), loadingHeader);
      expect(
        tester.getSize(find.byType(MetroScheduleSection)).height,
        closeTo(loadingSize.height, 1),
      );
    });

    testWidgets('each row announces its own times to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const MetroScheduleSection(
          schedule: [
            MetroSchedule(
              line: 'R',
              destination: '象山',
              firstTime: '06:02',
              lastTime: '00:34',
            ),
          ],
        ),
      );

      expect(
        find.bySemanticsLabel('往象山，首班車 06:02，末班車 00:34'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
