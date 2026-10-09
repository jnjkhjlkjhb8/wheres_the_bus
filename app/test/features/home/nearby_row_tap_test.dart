import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
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
}
