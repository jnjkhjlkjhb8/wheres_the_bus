import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
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

  /// The painted segments of the meter, in draw order.
  List<Color?> segments(WidgetTester tester) => tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(CrowdMeter),
          matching: find.byType(Container),
        ),
      )
      .map((c) => (c.decoration! as BoxDecoration).color)
      .toList();

  testWidgets('an unknown reading draws nothing at all', (tester) async {
    // The whole point: an empty meter would read as an empty bus, and 26% of
    // vehicles report no level.
    await pump(
      tester,
      const CrowdMeter(level: CrowdLevel.unknown),
    );

    expect(find.byType(Container), findsNothing);
  });

  testWidgets('fills one, two, three segments by level', (tester) async {
    for (final (level, filled) in [
      (CrowdLevel.comfortable, 1),
      (CrowdLevel.normal, 2),
      (CrowdLevel.crowded, 3),
    ]) {
      await pump(tester, CrowdMeter(level: level));

      final colors = segments(tester);
      expect(colors, hasLength(3), reason: 'meter is always three segments');
      final empty = AppTheme.light.colorScheme.outline;
      expect(
        colors.where((c) => c != empty).length,
        filled,
        reason: '$level fills $filled segments',
      );
    }
  });

  testWidgets('only 擁擠 takes full ink', (tester) async {
    final ink = AppTheme.light.colorScheme.onSurface;
    final secondary = AppTheme.light.colorScheme.onSurfaceVariant;

    await pump(
      tester,
      const CrowdMeter(level: CrowdLevel.crowded),
    );
    expect(segments(tester).first, ink);

    await pump(
      tester,
      const CrowdMeter(level: CrowdLevel.normal),
    );
    expect(segments(tester).first, secondary);
  });

  testWidgets('carries the reading as words for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      const CrowdMeter(level: CrowdLevel.crowded),
    );

    expect(find.bySemanticsLabel('車上擁擠'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the ETA row shows the meter under the time', (tester) async {
    await pump(
      tester,
      const EtaListTile(
        routeNo: '307',
        destination: '板橋',
        status: EtaMinutes(3),
        crowdLevel: CrowdLevel.crowded,
      ),
    );

    expect(find.byType(CrowdMeter), findsOneWidget);
    final time = tester.getCenter(find.text('3'));
    final meter = tester.getCenter(find.byType(CrowdMeter));
    expect(meter.dy, greaterThan(time.dy), reason: 'meter sits below the time');
  });

  testWidgets('a service-over row drops the meter', (tester) async {
    // 末班已過 / 今日未營運: there is no bus left to be full.
    await pump(
      tester,
      const EtaListTile(
        routeNo: '307',
        destination: '板橋',
        status: EtaLabel('末班已過'),
        muted: true,
        crowdLevel: CrowdLevel.crowded,
      ),
    );

    expect(find.byType(CrowdMeter), findsNothing);
  });
}
