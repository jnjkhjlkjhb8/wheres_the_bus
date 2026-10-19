import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_search_screen_back_nav');
    await Hive.openBox<dynamic>('settings');
    await Hive.openBox<dynamic>('saved_plans');
  });

  Future<GoRouter> pumpAt(WidgetTester tester, String location) async {
    final router = AppRouter.createRouter(initialLocation: location);
    final alertBloc = AlertBloc();
    final planBloc = PlanBloc();
    final trackBloc = MrtTrackBloc(i18n: lookupAppI18n(const Locale('zh')));
    final favoritesBloc = FavoritesBloc(
      FavoritesRepository.instance,
      App.isInitialized,
    );
    addTearDown(router.dispose);
    addTearDown(alertBloc.close);
    addTearDown(planBloc.close);
    addTearDown(trackBloc.close);
    addTearDown(favoritesBloc.close);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AlertBloc>.value(value: alertBloc),
          BlocProvider<PlanBloc>.value(value: planBloc),
          BlocProvider<MrtTrackBloc>.value(value: trackBloc),
          BlocProvider<FavoritesBloc>.value(value: favoritesBloc),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
        ),
      ),
    );
    await tester.pump();
    return router;
  }

  Future<void> tapClose(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('goes home when search is the only stack entry', (
    tester,
  ) async {
    final router = await pumpAt(tester, AppRoutes.search);
    expect(router.canPop(), isFalse);

    await tapClose(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(SearchScreen), findsNothing);
  });

  testWidgets('pops back to what pushed it otherwise', (tester) async {
    final router = await pumpAt(tester, AppRoutes.home);
    unawaited(router.push(AppRoutes.search));
    await tester.pumpAndSettle();
    expect(router.canPop(), isTrue);

    await tapClose(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(SearchScreen), findsNothing);
    expect(router.canPop(), isFalse);
  });
}
