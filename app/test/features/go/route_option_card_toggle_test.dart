import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

PlanRoute _route() => const PlanRoute(
  travelTime: 600,
  startTime: '2026-07-11T08:00:00',
  endTime: '2026-07-11T08:10:00',
  transfers: 0,
  sections: [],
);

void main() {
  testWidgets('bookmark tap fires onToggleSave, not the card onTap', (
    tester,
  ) async {
    var toggled = 0;
    var tapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: Scaffold(
          body: RouteOptionCard(
            route: _route(),
            highlighted: false,
            isSaved: true,
            onTap: () => tapped++,
            onToggleSave: () => toggled++,
          ),
        ),
      ),
    );

    // The filled bookmark is the only save control on a saved card.
    await tester.tap(find.byIcon(Icons.bookmark_rounded));
    await tester.pumpAndSettle();

    expect(toggled, 1, reason: 'bookmark tap must reach onToggleSave');
    expect(tapped, 0, reason: 'card onTap must not fire from a bookmark tap');
  });

  testWidgets('bookmark tap still works inside a scrollable list', (
    tester,
  ) async {
    var toggled = 0;
    var tapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        home: Scaffold(
          body: ListView(
            children: [
              RouteOptionCard(
                route: _route(),
                highlighted: false,
                isSaved: true,
                onTap: () => tapped++,
                onToggleSave: () => toggled++,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.bookmark_rounded));
    await tester.pumpAndSettle();

    expect(toggled, 1, reason: 'bookmark tap must reach onToggleSave');
    expect(tapped, 0, reason: 'card onTap must not fire from a bookmark tap');
  });
}
