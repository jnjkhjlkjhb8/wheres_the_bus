import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart'
    show PlanFailureKind;
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import 'go_plan_overlay_test.dart' show route, section;
import 'support/go_harness.dart';

// The entry surface never goes idle, so pumpAndSettle would time out.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  final harness = GoHarness()..install();
  final i18n = lookupAppI18n(const Locale('zh'));

  PlanState success({
    List<PlanRoute>? routes,
    String next = '',
    String previous = '',
    PlanStatus status = PlanStatus.success,
  }) => PlanState(
    status: status,
    result: PlanResult(
      routes:
          routes ??
          [
            route([section(walk: true)]),
            route([section()]),
          ],
      nextPageCursor: next,
      previousPageCursor: previous,
    ),
    selectedRouteIndex: 0,
  );

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text).first).style!;

  testWidgets('the floating header card follows the theme', (tester) async {
    for (final dark in [false, true]) {
      await harness.pump(
        tester,
        success(),
        destination: goTestDestination,
        dark: dark,
      );
      await tester.pump();
      final scheme = dark
          ? AppTheme.dark.colorScheme
          : AppTheme.light.colorScheme;
      final card = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere(
            (d) =>
                d.boxShadow != null &&
                d.boxShadow!.isNotEmpty &&
                d.border == null &&
                d.borderRadius == BorderRadius.circular(AppTheme.radiusCard),
          );
      expect(card.color, dark ? scheme.surfaceContainerHigh : Colors.white);
      await harness.dispose(tester);
    }
  });

  testWidgets('the rail centres each glyph on its row', (tester) async {
    await harness.pump(tester, success(), destination: goTestDestination);
    await tester.pump();
    final rail = find.ancestor(
      of: find.byIcon(Icons.radio_button_checked_rounded),
      matching: find.byType(SizedBox),
    );
    final box = tester.widget<SizedBox>(rail.first);
    expect((box.width, box.height), (14, 96));
    EdgeInsets padOf(IconData icon) => tester
        .widget<Padding>(
          find
              .ancestor(of: find.byIcon(icon), matching: find.byType(Padding))
              .first,
        )
        .padding
        .resolve(TextDirection.ltr);
    expect(
      padOf(Icons.radio_button_checked_rounded),
      EdgeInsets.only(top: 24 - AppTheme.space6),
    );
    expect(
      padOf(Icons.location_on_rounded),
      EdgeInsets.only(bottom: 24 - AppTheme.space8),
    );
    expect(find.byIcon(Icons.location_on_rounded), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('a chosen destination reads strong', (
    tester,
  ) async {
    final scheme = AppTheme.light.colorScheme;
    await harness.pump(tester, success(), destination: goTestDestination);
    await tester.pump();
    var style = styleOf(tester, '目的地');
    expect(style.color, scheme.onSurface);
    expect(style.fontWeight, FontWeight.w600);
    await harness.dispose(tester);
  });

  testWidgets('the origin row states a missing origin muted', (tester) async {
    final scheme = AppTheme.light.colorScheme;
    harness.location.enabled = false;
    await harness.pump(tester, const PlanState());
    await _settle(tester);
    final style = styleOf(tester, i18n.goChooseOrigin);
    expect(style.color, scheme.onSurfaceVariant);
    expect(style.fontWeight, FontWeight.w400);
    expect(find.text(i18n.goNoLocation), findsOneWidget);
    expect(find.text(i18n.goEnableLocation), findsWidgets);
    await harness.dispose(tester);
  });

  testWidgets('a located origin reads strong with the locate glyph', (
    tester,
  ) async {
    final scheme = AppTheme.light.colorScheme;
    await harness.pump(tester, const PlanState());
    await _settle(tester);
    expect(find.byIcon(Icons.my_location_rounded), findsWidgets);
    expect(find.text(i18n.goNoLocation), findsNothing);
    final label = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere(
          (t) =>
              t.style?.fontWeight == FontWeight.w600 &&
              t.style?.color == scheme.onSurface,
        );
    expect(label.data, isNotEmpty);
    await harness.dispose(tester);
  });

  testWidgets('the sheet title counts suggestions only once they landed', (
    tester,
  ) async {
    await harness.pump(tester, success(), destination: goTestDestination);
    await tester.pump();
    expect(find.text(i18n.goSuggestedRoutes), findsOneWidget);
    expect(find.text(i18n.suggestionCount(2)), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.text(i18n.goOptions), findsOneWidget);
    await harness.dispose(tester);
    await harness.pump(
      tester,
      success(status: PlanStatus.loading),
      destination: goTestDestination,
    );
    await tester.pump();
    expect(find.text(i18n.suggestionCount(2)), findsNothing);
    expect(find.text(i18n.goPlanning), findsWidgets);
    await harness.dispose(tester);
  });

  testWidgets('paging actions frame the list and the first card leads', (
    tester,
  ) async {
    await harness.pump(
      tester,
      success(next: 'n', previous: 'p'),
      destination: goTestDestination,
    );
    await tester.pump();
    expect(find.text(i18n.goEarlierDepartures), findsOneWidget);
    expect(find.text(i18n.goLaterDepartures), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    final cards = tester
        .widgetList<RouteOptionCard>(find.byType(RouteOptionCard))
        .toList();
    expect([for (final c in cards) c.highlighted], [true, false]);
    await harness.dispose(tester);
  });

  testWidgets('failures pick their glyph by kind', (tester) async {
    for (final (kind, icon) in [
      (PlanFailureKind.noRoute, Icons.alt_route_rounded),
      (PlanFailureKind.timeout, Icons.cloud_off_rounded),
    ]) {
      await harness.pump(
        tester,
        PlanState(status: PlanStatus.failure, failure: kind),
        destination: goTestDestination,
      );
      await tester.pump();
      expect(find.byIcon(icon), findsOneWidget);
      await harness.dispose(tester);
    }
  });
}
