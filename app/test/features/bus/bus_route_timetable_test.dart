import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/i18n.dart';

// A Tuesday, so "today" is weekday index 1.
final _clock = DateTime(2026, 10, 13, 8, 10);

BusDailyTrip _trip(String time, {bool lowFloor = false}) => BusDailyTrip(
  tripId: time,
  isLowFloor: lowFloor,
  stopTimes: [
    BusStopTime(stopSequence: 1, departureTime: '$time:00', arrivalTime: ''),
  ],
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  i18nApp(Scaffold(body: SingleChildScrollView(child: child))),
);

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text).first).style!;

void main() {
  testWidgets('marks only the next departure and tags low-floor trips', (
    tester,
  ) async {
    final state = BusRouteState(
      daily: BusDailyTimetable(
        directions: {
          0: [
            _trip('07:00', lowFloor: true),
            _trip('08:15'),
            _trip('09:00', lowFloor: true),
          ],
        },
      ),
    );
    await _pump(
      tester,
      BusRouteTimetable(
        cs: const ColorScheme.light(),
        headsign: '板橋',
        state: state,
        clock: () => _clock,
      ),
    );

    final i18n = AppI18n.of(tester.element(find.byType(BusRouteTimetable)));
    expect(find.text(i18n.busNextRun), findsOneWidget);
    expect(find.text(i18n.busLowFloor), findsNWidgets(2));
    expect(_styleOf(tester, i18n.busNextRun).fontSize, 10);
    expect(_styleOf(tester, i18n.busNextRun).height, 1.2);
    expect(_styleOf(tester, i18n.busNextRun).fontWeight, FontWeight.w700);
    expect(_styleOf(tester, i18n.busLowFloor).fontWeight, FontWeight.w600);
    expect(_styleOf(tester, '08:15').fontSize, 16);
    expect(_styleOf(tester, '08:15').fontWeight, FontWeight.w700);
    expect(_styleOf(tester, '07:00').fontWeight, FontWeight.w400);
    expect(find.text(i18n.busRunCount(3)), findsOneWidget);
  });

  testWidgets('headway window reads fixed or ranged by its bounds', (
    tester,
  ) async {
    Future<void> show(String min, String max) => _pump(
      tester,
      BusHeadwayRow(
        window: (start: '06:00', end: '22:00', minMins: min, maxMins: max),
        cs: const ColorScheme.light(),
      ),
    );

    await show('15', '15');
    final i18n = AppI18n.of(tester.element(find.byType(BusHeadwayRow)));
    expect(find.text(i18n.busHeadwayFixed('15')), findsOneWidget);
    expect(_styleOf(tester, '06:00–22:00').fontSize, 16);

    await show('15', '20');
    expect(find.text(i18n.busHeadwayRange('15', '20')), findsOneWidget);
  });
}
