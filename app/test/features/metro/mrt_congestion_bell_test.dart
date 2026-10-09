import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/i18n.dart';

void main() {
  Future<void> pump(WidgetTester tester, MetroArrival arrival) =>
      tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,

          theme: AppTheme.light,
          home: Scaffold(
            body: BlocProvider(
              create: (_) => MrtTrackBloc(
                i18n: zhStrings,
                liveActivityEnabled: () => false,
              ),
              child: MetroArrivalTile(arrival: arrival),
            ),
          ),
        ),
      );

  const bl = MetroArrival(
    line: 'BL',
    destination: '南港展覽館',
    estimateSeconds: 120,
    system: 'TRTC',
    stationId: 'BL12',
    destinationStationId: 'BL23',
    trainNumber: '215',
    cn1: '163/164',
    congestion: [1, 2, 2, 2, 2, 1],
  );

  testWidgets('congestion levels render the strip with its label', (
    tester,
  ) async {
    await pump(tester, bl);
    expect(find.text('車廂擁擠度'), findsOneWidget);
    expect(find.text('暫無資料'), findsNothing);
  });

  testWidgets('absent congestion renders the 暫無資料 placeholder', (
    tester,
  ) async {
    await pump(
      tester,
      const MetroArrival(
        line: 'BL',
        destination: '南港展覽館',
        estimateSeconds: 120,
        system: 'TRTC',
        stationId: 'BL12',
        destinationStationId: 'BL23',
      ),
    );
    expect(find.text('暫無資料'), findsOneWidget);
    expect(find.text('車廂擁擠度'), findsNothing);
  });

  testWidgets('a high-capacity TRTC arrival shows the alight bell', (
    tester,
  ) async {
    await pump(tester, bl);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
  });

  testWidgets('a Wenhu (BR) arrival never shows the bell', (tester) async {
    await pump(
      tester,
      const MetroArrival(
        line: 'BR',
        destination: '動物園',
        estimateSeconds: 180,
        system: 'TRTC',
        stationId: 'BR10',
        destinationStationId: 'BR01',
        congestion: [1, 2, 3, 1],
      ),
    );
    // Congestion still renders for BR, but the reminder bell does not.
    expect(find.text('車廂擁擠度'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
    expect(find.byIcon(Icons.notifications_active_rounded), findsNothing);
  });

  testWidgets('a non-TRTC arrival never shows the bell', (tester) async {
    await pump(
      tester,
      const MetroArrival(
        line: 'BL',
        destination: '南港展覽館',
        estimateSeconds: 120,
        system: 'TYMC',
        stationId: 'BL12',
        destinationStationId: 'BL23',
      ),
    );
    expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
  });
}
