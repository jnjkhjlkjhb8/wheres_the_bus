import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

RailTrainStop _stop(String name, String time, {String? depart}) =>
    RailTrainStop(name: name, arrive: time, depart: depart ?? time);

// One stop every ten minutes from 08:00.
final List<RailTrainStop> _stops = [
  _stop('甲', '08:00'),
  _stop('乙', '08:10'),
  _stop('丙', '08:20'),
  _stop('丁', '08:30'),
  _stop('戊', '08:40'),
  _stop('己', '08:50'),
];

void main() {
  final i18n = lookupAppI18n(const Locale('zh'));

  Future<void> show(
    WidgetTester tester, {
    List<RailTrainStop>? stops,
    DateTime? at,
    String? origin,
    String? alight,
    bool picking = false,
    int lead = 0,
    ValueChanged<String>? onPick,
    DateTime? updated,
  }) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: RailTrainTimetableTab(
            stops: stops ?? _stops,
            serviceDate: '2030-01-02',
            delayMinutes: 0,
            delayUpdatedAt: updated,
            alight: alight,
            userOrigin: origin,
            picking: picking,
            leadStops: lead,
            onPickStop: onPick,
            clock: () => at ?? DateTime(2030, 1, 2, 7),
          ),
        ),
      ),
    );
  }

  List<TimelineSpine> spines(WidgetTester tester) =>
      tester.widgetList<TimelineSpine>(find.byType(TimelineSpine)).toList();

  testWidgets('passed stops fold into one summary that expands', (
    tester,
  ) async {
    await show(tester, at: DateTime(2030, 1, 2, 8, 35));

    expect(find.text(i18n.railStopsPassedPreview(3, '甲、乙、丙')), findsOneWidget);
    expect(find.text('甲'), findsNothing);
    expect(find.text('丁'), findsOneWidget);

    await tester.tap(find.text(i18n.railStopsPassedPreview(3, '甲、乙、丙')));
    await tester.pump();

    expect(find.text('甲'), findsOneWidget);
    expect(find.textContaining('已過'), findsNothing);
  });

  testWidgets('a single passed stop is not worth a summary', (tester) async {
    await show(tester, at: DateTime(2030, 1, 2, 8, 15));

    expect(find.textContaining('已過'), findsNothing);
    expect(find.text('甲'), findsOneWidget);
  });

  testWidgets('the spine is covered down to the train', (tester) async {
    await show(tester, at: DateTime(2030, 1, 2, 8, 15));

    final s = spines(tester);
    expect(s.map((e) => e.travelledAbove), [
      true,
      true,
      false,
      false,
      false,
      false,
    ]);
    expect(s.map((e) => e.travelledBelow), [
      true,
      false,
      false,
      false,
      false,
      false,
    ]);
    expect(s.first.lineAbove, isFalse);
    expect(s.last.lineBelow, isFalse);
    expect(s[2].lineAbove && s[2].lineBelow, isTrue);
  });

  testWidgets('board and alight stops are marked, ends are termini', (
    tester,
  ) async {
    await show(tester, origin: '乙', alight: '丁');

    expect(spines(tester).map((e) => e.kind), [
      TimelineNodeKind.terminus,
      TimelineNodeKind.emphasis,
      TimelineNodeKind.intermediate,
      TimelineNodeKind.emphasis,
      TimelineNodeKind.intermediate,
      TimelineNodeKind.terminus,
    ]);
    expect(find.text(i18n.railBoard), findsOneWidget);
    expect(find.text(i18n.railAlight), findsOneWidget);
    FontWeight? weight(String n) =>
        tester.widget<Text>(find.text(n)).style!.fontWeight;
    expect(weight('乙'), FontWeight.w700);
    expect(weight('丁'), FontWeight.w700);
    expect(weight('丙'), FontWeight.w400);
    expect(tester.widget<Text>(find.text('丙')).style!.height, 1.3);
  });

  testWidgets('the lead stop is the alight stop minus the lead', (
    tester,
  ) async {
    Finder bell() => find.byIcon(Icons.notifications_rounded);

    await show(tester, alight: '己', lead: 2);
    expect(bell(), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('丁'), matching: find.byType(Row)).first,
        matching: bell(),
      ),
      findsOneWidget,
    );

    await show(tester, alight: '己');
    expect(bell(), findsNothing);

    await show(tester, alight: '乙', lead: 3);
    expect(bell(), findsNothing);
  });

  testWidgets('only stops after the boarding stop can be picked', (
    tester,
  ) async {
    final picked = <String>[];
    await show(tester, origin: '乙', picking: true, onPick: picked.add);

    await tester.tap(find.text('甲'));
    await tester.tap(find.text('乙'));
    await tester.tap(find.text('丙'));

    expect(picked, ['丙']);
  });

  testWidgets('rows are inert unless picking with a handler', (tester) async {
    final picked = <String>[];
    await show(tester, origin: '乙', onPick: picked.add);
    await tester.tap(find.text('丁'));
    expect(picked, isEmpty);

    await show(tester, origin: '乙', picking: true);
    expect(
      tester
          .widgetList<Pressable>(find.byType(Pressable))
          .where((p) => p.onTap != null),
      isEmpty,
    );
  });

  testWidgets('a dwell of two minutes or more is called out', (tester) async {
    await show(
      tester,
      stops: [
        _stop('甲', '08:00'),
        _stop('乙', '08:10', depart: '08:11'),
        _stop('丙', '08:20', depart: '08:22'),
        _stop('丁', '08:30', depart: '08:35'),
        _stop('戊', '08:40'),
      ],
    );

    expect(find.text(i18n.railDwellMinutes(1)), findsNothing);
    expect(find.text(i18n.railDwellMinutes(2)), findsOneWidget);
    expect(find.text(i18n.railDwellMinutes(5)), findsOneWidget);
  });

  testWidgets('the header names its columns with open tracking', (
    tester,
  ) async {
    await show(tester, updated: DateTime(2030, 1, 2, 8, 5));

    final style = tester.widget<Text>(find.text(i18n.railColStation)).style!;
    expect(style.letterSpacing, 0.4);
    expect(style.fontSize, AppTextStyles.bodyVerySmall.fontSize);
    expect(find.text(i18n.railColElapsed), findsOneWidget);
    expect(find.text(i18n.railColTime), findsOneWidget);
  });

  testWidgets('boarding at the terminus drops the elapsed column', (
    tester,
  ) async {
    await show(tester, origin: '己');

    expect(find.text(i18n.railColElapsed), findsNothing);
  });

  testWidgets('elapsed time counts from the boarding stop', (tester) async {
    await show(tester, origin: '乙');

    expect(find.text(i18n.railElapsedPlus(10)), findsOneWidget);
    expect(find.text(i18n.railElapsedPlus(40)), findsOneWidget);
  });
}
