import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_switch.dart';
import 'package:wheres_the_bus/shared/widgets/filter_chip_group.dart';

/// Opens the options sheet and hands back whatever 套用 returned.
Future<PlanOptions?> _open(
  WidgetTester tester, {
  required PlannerCapabilities capabilities,
  PlanOptions initial = const PlanOptions(),
  Future<void> Function(WidgetTester, AppI18n)? interact,
}) async {
  PlanOptions? result;
  late AppI18n i18n;

  // A viewport tall enough for the whole sheet. The controls live in a
  // ListView, so anything below the fold would not be built at all, and a
  // test that scrolled to reach them could not then assert on their order.
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Builder(
        builder: (context) {
          i18n = AppI18n.of(context);
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showOptionsSheet(
                    context,
                    current: initial,
                    capabilities: capabilities,
                  );
                },
                child: const Text('open'),
              ),
            ),
          );
        },
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (interact != null) await interact(tester, i18n);
  return result;
}

const _motis = PlannerCapabilities({
  'transitModes',
  'itineraryCount',
  'transferWindow',
  'firstLastMile',
  'pricePreference',
  'maxTransfers',
  'avoidReservation',
  'carryBike',
});

void main() {
  testWidgets('a TDX-backed planner offers none of the MOTIS-only controls', (
    tester,
  ) async {
    await _open(tester, capabilities: const PlannerCapabilities.shared());
    final i18n = await AppI18n.delegate.load(const Locale('zh'));

    // The shared five are still there…
    expect(find.text(i18n.goModes), findsOneWidget);
    expect(find.text(i18n.goTransferTime), findsOneWidget);
    // …and nothing TDX would silently ignore.
    expect(find.text(i18n.goMaxTransfers), findsNothing);
    expect(find.text(i18n.goAvoidReservation), findsNothing);
    expect(find.text(i18n.goCarryBike), findsNothing);
  });

  testWidgets('MOTIS adds its three, after the shared five', (tester) async {
    await _open(tester, capabilities: _motis);
    final i18n = await AppI18n.delegate.load(const Locale('zh'));

    expect(find.text(i18n.goMaxTransfers), findsOneWidget);
    expect(find.text(i18n.goAvoidReservation), findsOneWidget);
    expect(find.text(i18n.goCarryBike), findsOneWidget);

    // Order matters: the shared controls keep their positions so the sheet
    // does not reshuffle under the rider when the backend changes.
    final modes = tester.getTopLeft(find.text(i18n.goModes)).dy;
    final cap = tester.getTopLeft(find.text(i18n.goMaxTransfers)).dy;
    expect(cap, greaterThan(modes));
  });

  testWidgets('an untouched transfer cap is left unset, not sent as zero', (
    tester,
  ) async {
    final applied = await _open(
      tester,
      capabilities: _motis,
      interact: (tester, i18n) async {
        await tester.tap(find.text(i18n.commonApply));
        await tester.pumpAndSettle();
      },
    );

    expect(
      applied?.maxTransfers,
      isNull,
      reason:
          'zero means direct-only; a rider who never touched the control '
          'has not asked for that',
    );
  });

  testWidgets('mode toggles preserve at least one selected mode', (
    tester,
  ) async {
    final applied = await _open(
      tester,
      capabilities: _motis,
      initial: const PlanOptions(transitModes: [3]),
      interact: (tester, i18n) async {
        FilterChipGroup<int> modes() => tester.widget<FilterChipGroup<int>>(
          find.byType(FilterChipGroup<int>).first,
        );
        modes().onToggle(3);
        await tester.pumpAndSettle();
        expect(modes().selected, {3});
        modes().onToggle(4);
        await tester.pumpAndSettle();
        modes().onToggle(3);
        await tester.pumpAndSettle();
        expect(modes().selected, {4});
        await tester.tap(find.text(i18n.commonApply));
        await tester.pumpAndSettle();
      },
    );
    expect(applied?.transitModes, [4]);
  });

  testWidgets('choosing 直達 sends a real zero', (tester) async {
    final applied = await _open(
      tester,
      capabilities: _motis,
      interact: (tester, i18n) async {
        await tester.tap(find.text(i18n.goMaxTransfersDirect));
        await tester.pumpAndSettle();
        await tester.tap(find.text(i18n.commonApply));
        await tester.pumpAndSettle();
      },
    );

    expect(applied?.maxTransfers, 0);
  });

  testWidgets('going back to 不限 clears the cap again', (tester) async {
    final applied = await _open(
      tester,
      capabilities: _motis,
      initial: const PlanOptions(maxTransfers: 0),
      interact: (tester, i18n) async {
        await tester.tap(find.text(i18n.goMaxTransfersAny));
        await tester.pumpAndSettle();
        await tester.tap(find.text(i18n.commonApply));
        await tester.pumpAndSettle();
      },
    );

    expect(
      applied?.maxTransfers,
      isNull,
      reason: 'the segment has to be able to reach "unset", not just 0',
    );
  });

  testWidgets('the two switches survive the round trip', (tester) async {
    final applied = await _open(
      tester,
      capabilities: _motis,
      interact: (tester, i18n) async {
        // The switch is the control, not its label — tapping the words does
        // nothing, which is itself worth pinning down.
        await tester.tap(find.byType(AppSwitch).at(0));
        await tester.tap(find.byType(AppSwitch).at(1));
        await tester.pumpAndSettle();
        await tester.tap(find.text(i18n.commonApply));
        await tester.pumpAndSettle();
      },
    );

    expect(applied?.avoidReservation, isTrue);
    expect(applied?.carryBike, isTrue);
  });
}
