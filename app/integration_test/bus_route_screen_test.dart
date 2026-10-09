import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';

Widget _host() => MaterialApp(
  theme: AppTheme.light,
  home: const BusRouteScreen(subRouteUid: 'integration-test'),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await HiveStore.init();
  });

  group('BusRouteScreen', () {
    testWidgets('opens on the dynamic tab with the route header and stops', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text('261'), findsOneWidget);
      expect(find.text('動態資訊'), findsOneWidget);
      expect(find.text('路線詳細資料'), findsOneWidget);
      expect(find.text('壽山高中'), findsWidgets);
    });

    testWidgets('switches to the detail tab and shows fares and operator', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      await tester.tap(find.text('路線詳細資料'));
      await tester.pumpAndSettle();

      expect(find.text('票價資訊'), findsOneWidget);
      expect(find.text('營運業者'), findsWidgets);
      expect(find.text('桃園客運'), findsWidgets);
      expect(find.text('03-000000'), findsOneWidget);
    });

    testWidgets('toggles travel direction on the dynamic tab', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text('往 桃園火車站'), findsWidgets);

      await tester.tap(find.text('往 銘傳大學').first);
      await tester.pumpAndSettle();

      expect(find.text('壽山高中'), findsWidgets);
    });
  });
}
