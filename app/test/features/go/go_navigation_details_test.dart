import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import 'support/go_harness.dart';

const _p = PlanPoint(lat: 25, lng: 121);

PlanWalkStep _step(
  String instruction,
  double meters, {
  String modifier = '',
  String maneuver = 'turn',
}) => PlanWalkStep(
  instruction: instruction,
  maneuverType: maneuver,
  modifier: modifier,
  distanceMeters: meters,
  durationSeconds: 60,
  location: _p,
);

PlanSection _leg({
  required String type,
  String mode = '',
  String from = 'From',
  String to = 'To',
  String headsign = '',
  String arrivalTime = '',
  String departureTime = '',
  PlanIdentity identity = const PlanIdentity.empty(),
  List<PlanWalkStep> steps = const [],
  int stops = 0,
  int seconds = 600,
}) => PlanSection(
  type: type,
  travelSummary: PlanTravelSummary(duration: seconds, length: 0),
  departure: PlanPlace(
    name: from,
    type: '',
    location: _p,
    time: departureTime,
  ),
  arrival: PlanPlace(name: to, type: '', location: _p, time: arrivalTime),
  transport: PlanTransport(
    mode: mode,
    name: '307',
    shortName: '307',
    longName: '',
    headsign: headsign,
    category: '',
    routeColor: '',
  ),
  intermediateStops: [
    for (var i = 0; i < stops; i++)
      const PlanStop(name: 's', location: _p, departureTime: ''),
  ],
  identity: identity,
  walkSteps: steps,
);

PlanIdentity _identity(String type, {bool supported = true}) => PlanIdentity(
  routeType: type,
  routeKey: 'k',
  direction: '0',
  departureStopKey: 'a',
  arrivalStopKey: 'b',
  supported: supported,
);

void main() {
  final harness = GoHarness()..install();
  final i18n = lookupAppI18n(const Locale('zh'));
  final light = AppTheme.light.colorScheme;

  PlanState navigating(PlanSection leg, {int step = 0}) => PlanState(
    status: PlanStatus.success,
    result: PlanResult(
      routes: [
        PlanRoute(
          travelTime: 600,
          startTime: '',
          endTime: '2026-08-18T09:30:00',
          transfers: 0,
          sections: [leg],
        ),
      ],
    ),
    selectedRouteIndex: 0,
    activeLegIndex: 0,
    activeWalkStepIndex: step,
  );

  Iterable<Text> richTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .where((t) => t.textSpan is TextSpan);

  Text rich(WidgetTester tester, String startsWith) => richTexts(
    tester,
  ).firstWhere((t) => t.textSpan!.toPlainText().startsWith(startsWith));

  Text plain(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text).first);

  testWidgets('step distance switches to kilometres at exactly 1000 m', (
    tester,
  ) async {
    for (final (meters, value, unit) in [
      (999.0, '999', '公尺'),
      (1000.0, '1.0', '公里'),
      (2400.0, '2.4', '公里'),
    ]) {
      await harness.pump(
        tester,
        navigating(
          _leg(
            type: 'walk',
            steps: [
              _step('depart', meters),
              _step('turn here', 50, modifier: 'left'),
              _step('later', 30, modifier: 'right'),
              _step('arrive', 0, maneuver: 'arrive'),
            ],
          ),
        ),
      );
      await tester.pump();
      final text = rich(tester, value);
      expect(text.textSpan!.toPlainText(), '$value $unit', reason: '$meters');
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.last.style!.fontSize, 15);
      expect(spans.last.style!.fontWeight, FontWeight.w600);
      expect(text.style!.fontSize, 26);
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.style!.height, 1.15);
      await harness.dispose(tester);
    }
  });

  testWidgets('the announced step and the next strip carry their sizes', (
    tester,
  ) async {
    await harness.pump(
      tester,
      navigating(
        _leg(
          type: 'walk',
          steps: [
            _step('depart', 1500),
            _step('turn here', 80, modifier: 'left'),
            _step('then there', 20, modifier: 'right'),
            _step('arrive', 0, maneuver: 'arrive'),
          ],
        ),
      ),
    );
    await tester.pump();
    final instruction = plain(tester, 'turn here').style!;
    expect(instruction.fontSize, 15);
    expect(instruction.fontWeight, FontWeight.w600);
    expect(instruction.color, light.onSurface);
    final label = plain(tester, i18n.goNext).style!;
    expect(label.fontSize, 12.5);
    final strip = rich(tester, 'then there');
    expect(strip.style!.fontSize, 12.5);
    expect(strip.textSpan!.toPlainText(), 'then there  80 公尺');
    final icons = tester.widgetList<Icon>(find.byType(Icon));
    expect(icons.where((i) => i.size == 36), isNotEmpty);
    await harness.dispose(tester);
  });

  testWidgets('arriving soon is a 22pt bold line', (tester) async {
    await harness.pump(
      tester,
      navigating(
        _leg(
          type: 'walk',
          steps: [
            _step('depart', 10),
            _step('arrive', 0, maneuver: 'arrive'),
          ],
        ),
        step: 1,
      ),
    );
    await tester.pump();
    final style = plain(tester, i18n.goArrivingSoon).style!;
    expect(style.fontSize, 22);
    expect(style.fontWeight, FontWeight.w700);
    await harness.dispose(tester);
  });

  testWidgets('a walk without steps titles where it heads', (tester) async {
    await harness.pump(
      tester,
      navigating(_leg(type: 'walk', to: 'Dest', seconds: 600)),
    );
    await tester.pump();
    final title = plain(tester, i18n.walkToward('Dest')).style!;
    expect((title.fontSize, title.fontWeight), (17, FontWeight.w700));
    final sub = plain(tester, i18n.aboutMinutes(10)).style!;
    expect(sub.fontSize, 13);
    final icon = tester
        .widgetList<Icon>(find.byType(Icon))
        .firstWhere((i) => i.icon == Icons.directions_walk_rounded);
    expect(icon.size, 28);
    await harness.dispose(tester);
  });

  testWidgets('a ride titles its vehicle and what remains', (tester) async {
    await harness.pump(
      tester,
      navigating(
        _leg(type: 'transit', mode: 'BUS', headsign: 'Head', stops: 4),
      ),
    );
    await tester.pump();
    expect(find.text(i18n.rideVehicle('307')), findsOneWidget);
    expect(find.text(i18n.towardsAndRemaining('Head', 4)), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('the header card follows the theme', (tester) async {
    for (final dark in [false, true]) {
      await harness.pump(
        tester,
        navigating(_leg(type: 'walk')),
        dark: dark,
      );
      await tester.pump();
      final scheme = dark ? AppTheme.dark.colorScheme : light;
      final card = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.boxShadow != null && d.boxShadow!.isNotEmpty);
      expect(card.color, dark ? scheme.surfaceContainerHigh : Colors.white);
      await harness.dispose(tester);
    }
  });

  group('trailing readout', () {
    Future<GoJourney> open(
      WidgetTester tester,
      PlanSection leg, {
      JourneySessionState? journey,
    }) async {
      final (_, js) = await harness.pump(tester, navigating(leg));
      if (journey != null) js.show(journey);
      await tester.pumpAndSettle();
      return js;
    }

    testWidgets('idle shows the section arrival clock at 24pt', (
      tester,
    ) async {
      await open(
        tester,
        _leg(type: 'walk', arrivalTime: '2026-08-18T08:05:00'),
      );
      expect(plain(tester, '08:05').style!.fontSize, 24);
      expect(plain(tester, i18n.goExpectedArrival).style!.fontSize, 11);
      await harness.dispose(tester);
    });

    testWidgets('a leg without a time falls back to the route arrival', (
      tester,
    ) async {
      await open(tester, _leg(type: 'walk'));
      expect(find.text('09:30'), findsOneWidget);
      await harness.dispose(tester);
    });

    testWidgets('a waiting bus with an eta counts down in 28pt', (
      tester,
    ) async {
      final js = await open(
        tester,
        _leg(type: 'transit', mode: 'MRT', identity: _identity('bus')),
        journey: const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration(seconds: 61),
        ),
      );
      expect(plain(tester, i18n.minutesValue(2)).style!.fontSize, 28);
      expect(find.text(i18n.goBusArriving), findsOneWidget);
      js.show(
        const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(i18n.minutesValue(1)), findsOneWidget);
      js.show(
        const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(i18n.etaArriving), findsOneWidget);
      js.show(
        const JourneySessionState(
          phase: JourneyPhase.riding,
          eta: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(i18n.etaArriving), findsNothing);
      await harness.dispose(tester);
    });

    testWidgets('a bus known only by its mode still counts down', (
      tester,
    ) async {
      await open(
        tester,
        _leg(
          type: 'transit',
          mode: 'BUS',
          identity: _identity('', supported: true),
        ),
        journey: const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration(seconds: 300),
        ),
      );
      expect(find.text(i18n.minutesValue(5)), findsOneWidget);
      await harness.dispose(tester);
    });

    testWidgets('an unsupported bus keeps the arrival clock', (tester) async {
      await open(
        tester,
        _leg(
          type: 'transit',
          mode: 'BUS',
          arrivalTime: '2026-08-18T08:05:00',
          identity: _identity('bus', supported: false),
        ),
        journey: const JourneySessionState(
          phase: JourneyPhase.waiting,
          eta: Duration(seconds: 300),
        ),
      );
      expect(find.text('08:05'), findsOneWidget);
      expect(find.text(i18n.minutesValue(5)), findsNothing);
      await harness.dispose(tester);
    });

    for (final (type, mode, rail) in [
      ('tra', '', true),
      ('thsr', '', true),
      ('', 'TRAIN', true),
      ('', 'HighSpeedTrain', true),
      ('bus', 'BUS', false),
      ('', 'MRT', false),
    ]) {
      testWidgets('a waiting $type/$mode leg ${rail ? 'shows' : 'hides'} its '
          'departure', (tester) async {
        await open(
          tester,
          _leg(
            type: 'transit',
            mode: mode,
            departureTime: '2026-08-18T07:45:00',
            arrivalTime: '2026-08-18T08:05:00',
            identity: _identity(type, supported: false),
          ),
          journey: const JourneySessionState(phase: JourneyPhase.waiting),
        );
        expect(find.text('07:45'), rail ? findsOneWidget : findsNothing);
        expect(
          find.text(i18n.busDeparture),
          rail ? findsOneWidget : findsNothing,
        );
        await harness.dispose(tester);
      });
    }

    testWidgets('a rail leg not waiting shows the arrival', (tester) async {
      await open(
        tester,
        _leg(
          type: 'transit',
          mode: 'TRA',
          departureTime: '2026-08-18T07:45:00',
          arrivalTime: '2026-08-18T08:05:00',
        ),
        journey: const JourneySessionState(phase: JourneyPhase.riding),
      );
      expect(find.text('08:05'), findsOneWidget);
      expect(find.text('07:45'), findsNothing);
      await harness.dispose(tester);
    });
  });
}
