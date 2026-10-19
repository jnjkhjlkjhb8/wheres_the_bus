import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/view/home_rail_query_sheet.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  testWidgets('home OD and train submissions keep query ids and service date', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Uri? currentUri;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: HomeRailQuerySheet()),
        ),
        GoRoute(
          path: '/rail',
          builder: (_, state) {
            currentUri = state.uri;
            return const Scaffold(body: Text('results'));
          },
        ),
        GoRoute(
          path: '/rail/train/:trainNo',
          builder: (_, state) {
            currentUri = state.uri;
            return const Scaffold(body: Text('train'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<RailQuerySheetContent>(find.byType(RailQuerySheetContent))
        .onSubmit(
          RailOdQuerySubmission(
            system: RailSystem.thsr,
            originName: '台北',
            originId: '01',
            destName: '左營',
            destId: '12',
            date: DateTime(2030, 1, 2, 9, 10),
            isDeparture: false,
          ),
        );
    await tester.pumpAndSettle();
    final od = currentUri!;
    expect(od.path, '/rail');
    expect(od.queryParameters['fromId'], '01');
    expect(od.queryParameters['toId'], '12');
    expect(od.queryParameters['dep'], '0');
    expect(od.queryParameters['submit'], '1');
    expect(
      DateTime.parse(od.queryParameters['date']!),
      DateTime(2030, 1, 2, 9, 10),
    );
    router.pop();
    await tester.pumpAndSettle();
    tester
        .widget<RailQuerySheetContent>(find.byType(RailQuerySheetContent))
        .onSubmit(
          RailTrainQuerySubmission(
            system: RailSystem.tra,
            trainNo: '123',
            date: DateTime(2030, 1, 2),
          ),
        );
    await tester.pumpAndSettle();
    final train = currentUri!;
    expect(train.path, '/rail/train/123');
    expect(train.queryParameters['sys'], 'tra');
    expect(train.queryParameters['date'], '2030-01-02');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
