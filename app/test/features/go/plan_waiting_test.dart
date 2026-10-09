import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _route = PlanRoute(
  travelTime: 1680,
  startTime: '08:00',
  endTime: '08:28',
  transfers: 1,
  sections: [],
);

Widget _harness(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(body: child),
);

// The shimmer loops forever, so pumpAndSettle would never return; every wait
// here is an explicit duration.
final Finder _skeletonCards = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('plan-skeleton-'),
);

void main() {
  testWidgets('the skeleton is as many cards as routes were asked for', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        PlanWaitingPanel(routeCount: 4, lastRoute: null, onCancel: () {}),
      ),
    );

    expect(find.text('正在規劃路線…'), findsOneWidget);
    // Four placeholders, so the real cards land in space already held.
    expect(_skeletonCards, findsNWidgets(4));

    // Let the escalation timers fire so none is left pending at teardown.
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the loading skeleton is as wide as a real route card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        PlanWaitingPanel(routeCount: 1, lastRoute: null, onCancel: () {}),
      ),
    );
    final skeletonWidth = tester.getSize(_skeletonCards.first).width;
    await tester.pump(const Duration(seconds: 9));

    // Same padding the results ListView.separated wraps each card in.
    await tester.pumpWidget(
      _harness(
        Padding(
          padding: const EdgeInsets.all(16),
          child: RouteOptionCard(
            route: _route,
            highlighted: false,
            onTap: () {},
          ),
        ),
      ),
    );
    final cardWidth = tester.getSize(find.byType(RouteOptionCard)).width;

    expect(skeletonWidth, cardWidth);
  });

  testWidgets(
    'the message escalates and cancel only appears once waiting is '
    'unreasonable',
    (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _harness(
          PlanWaitingPanel(
            routeCount: 2,
            lastRoute: null,
            onCancel: () => cancelled = true,
          ),
        ),
      );

      expect(find.text('取消'), findsNothing);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在比較轉乘組合…'), findsOneWidget);
      expect(find.text('取消'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('還在等交通部資料回覆'), findsOneWidget);

      await tester.tap(find.text('取消'));
      expect(cancelled, isTrue);
    },
  );

  testWidgets('a saved route for the same trip is offered while waiting', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        PlanWaitingPanel(routeCount: 1, lastRoute: _route, onCancel: () {}),
      ),
    );

    expect(find.text('上次這段路你走的是'), findsOneWidget);
    expect(find.text('約 28 分'), findsOneWidget);

    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the straight-line distance is stated, then yields to cancel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        PlanWaitingPanel(
          routeCount: 1,
          lastRoute: null,
          straightLineMeters: 3240,
          onCancel: () {},
        ),
      ),
    );

    expect(find.text('3.2'), findsOneWidget);

    // Once cancel earns its place the readout steps aside rather than
    // crowding the row.
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('3.2'), findsNothing);
    expect(find.text('取消'), findsOneWidget);
  });
}
