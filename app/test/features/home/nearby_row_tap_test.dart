import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  testWidgets('點附近車站列會以該站呼叫 onStationTap', (tester) async {
    const station = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'S1',
      stationName: '台北車站',
      lat: 25,
      lon: 121.5,
      walkingMinutes: 3,
      distanceMeters: 200,
    );
    NearStationViewModel? tapped;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: Scaffold(
          body: buildNearbyRowForTest(
            station: station,
            onStationTap: (s) => tapped = s,
          ),
        ),
      ),
    );
    await tester.tap(find.text('台北車站'));
    expect(tapped, station);
  });

  testWidgets('公車列寫出往哪裡與接下來兩班', (tester) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    const station = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'S1',
      stationName: '臺北車站(鄭州)',
      lat: 25,
      lon: 121.5,
      walkingMinutes: 3,
      distanceMeters: 200,
      headsigns: ['陽明山', '新北投'],
    );
    BusStopArrivalItem item(String route, int seconds) => BusStopArrivalItem(
      i18n,
      BusStopArrival(
        stationId: 'pole',
        subRouteUid: 'sub-$route',
        routeName: route,
        destination: '陽明山',
        estimateSeconds: seconds,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: buildNearbyRowForTest(
            station: station,
            onStationTap: (_) {},
            arrivals: [item('260', 180), item('218', 480)],
          ),
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.text('往陽明山、新北投')).style?.height,
      1.3,
    );
    expect(find.text('260 3分', findRichText: true), findsOneWidget);
    expect(find.text('218 8分', findRichText: true), findsOneWidget);
    TextStyle? timeStyle;
    tester
        .widget<RichText>(find.text('260 3分', findRichText: true))
        .text
        .visitChildren((span) {
          if (span is TextSpan && span.text == '3分') timeStyle = span.style;
          return true;
        });
    expect(timeStyle?.fontFamily, 'IBMPlexMono');
  });

  testWidgets('沒有往哪裡與到站時間時不多佔一行', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: buildNearbyRowForTest(
            station: const NearStationViewModel(
              type: NearStationType.mrt,
              stationId: 'BL12',
              stationName: '台北車站',
              lat: 25,
              lon: 121.5,
              walkingMinutes: 3,
              distanceMeters: 200,
            ),
            onStationTap: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('往'), findsNothing);
    expect(find.text('步行 3 分 · 200m'), findsOneWidget);
  });
}
