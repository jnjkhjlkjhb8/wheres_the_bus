import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_event.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/nav_mini_bar.dart';

import '../../features/go/go_plan_overlay_test.dart' show route, section;

class _Trip extends TripBloc {
  _Trip(TripState state) : super() {
    emit(state);
  }
  @override
  void add(TripEvent event) {}
  void show(TripState state) => emit(state);
}

void main() {
  Future<GoRouter> mount(WidgetTester tester, _Trip trip) async {
    Widget page(BuildContext context, GoRouterState state) => Scaffold(
      body: Column(children: [Text(state.uri.path), const NavMiniBar()]),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: page),
        GoRoute(path: '/go', builder: page),
      ],
    );
    await tester.pumpWidget(
      BlocProvider<TripBloc>.value(
        value: trip,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light,
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('a mini bar exists only for a valid active leg', (tester) async {
    final walking = route([section(walk: true)]);
    final trip = _Trip(const TripState());
    final router = await mount(tester, trip);
    for (final state in [
      const TripState(activeLegIndex: 0),
      TripState(route: walking),
      TripState(route: walking, activeLegIndex: -1),
      TripState(route: walking, activeLegIndex: 1),
      TripState(route: walking, activeLegIndex: 7),
    ]) {
      trip.show(state);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NavMiniBar),
          matching: find.byType(Pressable),
        ),
        findsNothing,
      );
    }
    trip.show(TripState(route: walking, activeLegIndex: 0));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(NavMiniBar),
        matching: find.byType(Pressable),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(walking.sections.last.arrival.name),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await tester.runAsync(trip.close);
  });

  testWidgets('the navigation bar opens go once and retains arrival time', (
    tester,
  ) async {
    final transit = route([section()]);
    final timed = PlanRoute(
      travelTime: transit.travelTime,
      startTime: '',
      endTime: '2026-10-10T12:30:00',
      transfers: 0,
      sections: transit.sections,
    );
    final trip = _Trip(TripState(route: timed, activeLegIndex: 0));
    final router = await mount(tester, trip);
    expect(find.text('12:30'), findsOneWidget);
    expect(tester.widget<Text>(find.text('12:30')).style!.fontSize, 16);
    final bar = find.descendant(
      of: find.byType(NavMiniBar),
      matching: find.byType(Pressable),
    );
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(find.text('/go'), findsOneWidget);
    final pages = router.routerDelegate.currentConfiguration.matches.length;
    await tester.tap(
      find
          .descendant(
            of: find.byType(NavMiniBar),
            matching: find.byType(Pressable),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(find.text('/go'), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.matches.length, pages);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await tester.runAsync(trip.close);
  });

  testWidgets('the bar follows the trip route', (tester) async {
    PlanRoute ending(String endTime) => PlanRoute(
      travelTime: 60,
      startTime: '',
      endTime: endTime,
      transfers: 0,
      sections: [section()],
    );
    final trip = _Trip(
      TripState(route: ending('2026-10-10T12:30:00'), activeLegIndex: 0),
    );
    final router = await mount(tester, trip);
    expect(find.text('12:30'), findsOneWidget);
    trip.show(
      TripState(route: ending('2026-10-10T14:45:00'), activeLegIndex: 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('14:45'), findsOneWidget);
    expect(find.text('12:30'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await tester.runAsync(trip.close);
  });
}
