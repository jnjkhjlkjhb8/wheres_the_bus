import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

// 2030-01-02 08:00, so a 09:00 departure is exactly 60 minutes away.
final _now = DateTime(2030, 1, 2, 8);

class _Rail extends RailBloc {
  _Rail(RailState initial) {
    emit(initial);
  }

  final events = <RailEvent>[];

  @override
  void add(RailEvent event) => events.add(event);
}

TraTimetableItem _train(
  String number,
  String depart,
  String arrive, {
  int delay = 0,
  bool suspended = false,
  bool added = false,
}) => TraTimetableItem(
  trainNo: number,
  trainType: '自強',
  departureTime: depart,
  arrivalTime: arrive,
  travelMinutes: 0,
  delayMinutes: delay,
  hasBike: false,
  hasDiningCar: false,
  isDisabledFriendly: false,
  hasBreastfeeding: false,
  remark: '',
  isSuspended: suspended,
  isAddedService: added,
);

void main() {
  final i18n = lookupAppI18n(const Locale('zh'));
  late _Rail rail;

  Future<void> showState(
    WidgetTester tester,
    RailState state, {
    DateTime? at,
    RailRouteArgs? args,
  }) async {
    tester.view.physicalSize = const Size(430, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = rail = _Rail(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: RailScreen(args: args, bloc: bloc, clock: () => at ?? _now),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> show(
    WidgetTester tester,
    List<TraTimetableItem> items, {
    String date = '2030-01-02',
    DateTime? at,
  }) => showState(
    tester,
    RailTimetableLoaded(
      system: RailSystem.tra,
      originName: '台北',
      destName: '台中',
      date: date,
      traItems: items,
      delays: {for (final t in items) t.trainNo: t.delayMinutes},
    ),
    at: at,
  );

  ColorScheme scheme(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(RailScreen))).colorScheme;

  TextStyle style(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text).first).style!;

  String labelOf(WidgetTester tester, String number) => tester
      .widgetList<Pressable>(find.byType(Pressable))
      .map((p) => p.semanticLabel ?? '')
      .firstWhere((l) => l.contains(' $number，'));

  testWidgets('the next train is larger and carries the countdown', (
    tester,
  ) async {
    await show(tester, [
      _train('1', '07:00', '08:00'),
      _train('2', '08:30', '09:30'),
    ]);
    final cs = scheme(tester);

    final next = style(tester, '08:30');
    expect(next.fontSize, 24);
    expect(next.fontWeight, FontWeight.w700);
    final past = style(tester, '07:00');
    expect(past.fontSize, 21);
    expect(past.fontWeight, FontWeight.w600);

    final note = style(tester, i18n.railInMinutes(30));
    expect(note.height, 1.2);
    expect(note.fontWeight, FontWeight.w600);
    expect(note.color, cs.onSurface);

    expect(labelOf(tester, '2'), contains(i18n.railDepartsIn(30)));
    expect(labelOf(tester, '1'), isNot(contains('後')));
  });

  testWidgets('arrival, duration and number have their own sizes', (
    tester,
  ) async {
    await show(tester, [_train('1', '08:30', '09:30')]);

    expect(style(tester, '09:30').fontSize, 17);
    expect(style(tester, '1時').fontSize, 11);
    expect(style(tester, '1').fontSize, 13);
  });

  testWidgets('the countdown stops past an hour', (tester) async {
    await show(tester, [_train('1', '09:00', '10:00')]);
    expect(find.text(i18n.railInMinutes(60)), findsOneWidget);
    expect(labelOf(tester, '1'), contains(i18n.railDepartsIn(60)));

    await show(tester, [_train('1', '09:01', '10:00')]);
    expect(find.text(i18n.railInMinutes(61)), findsNothing);
    expect(find.textContaining('分後'), findsNothing);
  });

  testWidgets('no countdown or spoken wait when the date is not today', (
    tester,
  ) async {
    await show(tester, [_train('1', '08:30', '09:30')], date: '2030-01-03');

    expect(find.textContaining('分後'), findsNothing);
    expect(labelOf(tester, '1'), isNot(contains('分後')));
  });

  testWidgets('an extra service is footnoted and spoken, a delay is critical', (
    tester,
  ) async {
    await show(tester, [
      _train('1', '07:00', '08:00', delay: 3),
      _train('2', '23:30', '23:50', added: true),
      _train('3', '07:30', '08:30', suspended: true),
    ]);
    final cs = scheme(tester);

    expect(find.text(i18n.railExtraService), findsWidgets);
    expect(style(tester, i18n.railExtraService).color, cs.onSurfaceVariant);
    expect(labelOf(tester, '2'), contains(i18n.railExtraService));
    expect(labelOf(tester, '1'), isNot(contains(i18n.railExtraService)));
    expect(style(tester, i18n.railDelayMinutes(3)).color, cs.error);
    expect(style(tester, i18n.railSuspendedShort).color, cs.error);
  });

  testWidgets('the header names the columns with open tracking', (
    tester,
  ) async {
    await show(tester, [_train('1', '08:30', '09:30')]);
    final cs = scheme(tester);

    for (final label in [
      i18n.railColDepart,
      i18n.railColArrive,
      i18n.railColTrainNo,
    ]) {
      final s = style(tester, label);
      expect(s.letterSpacing, 0.4, reason: label);
      expect(s.fontWeight, FontWeight.w600);
      expect(s.color, cs.onSurfaceVariant);
    }
  });

  testWidgets('the countdown follows the minutes of the clock', (tester) async {
    await show(tester, [
      _train('1', '08:30', '09:30'),
    ], at: DateTime(2030, 1, 2, 8, 10));

    expect(find.text(i18n.railInMinutes(20)), findsOneWidget);
  });

  testWidgets('a row with one unreadable time has no duration', (tester) async {
    await show(tester, [_train('1', '08:30', 'bad')]);

    expect(find.text('0分'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\d+[時分]').hasMatch(w.data ?? ''),
      ),
      findsNothing,
    );
  });

  testWidgets('the query summary dates the search month/day (weekday)', (
    tester,
  ) async {
    await show(tester, [_train('1', '08:30', '09:30')]);

    expect(find.textContaining('01/02 (三)'), findsWidgets);
  });

  testWidgets('empty and initial states keep their illustration', (
    tester,
  ) async {
    await showState(
      tester,
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );
    final empty = tester.widget<Icon>(find.byIcon(Icons.event_busy_rounded));
    expect(empty.size, 40);

    await showState(tester, const RailInitial());
    final initial = tester.widget<Icon>(find.byIcon(Icons.train_rounded));
    expect(initial.size, 40);
  });

  testWidgets('a cross-midnight arrival is marked as next day', (tester) async {
    await show(tester, [_train('1', '23:06', '00:30')]);

    expect(find.text(i18n.railNextDayMark), findsOneWidget);
    expect(labelOf(tester, '1'), contains(i18n.railNextDaySemantics));

    await show(tester, [_train('1', '08:06', '09:30')]);
    expect(find.text(i18n.railNextDayMark), findsNothing);
  });

  testWidgets('a late train states its delay-adjusted arrival', (tester) async {
    await show(tester, [_train('1', '08:30', '09:30', delay: 10)]);

    expect(find.text(i18n.railEstimatedArrive('09:40')), findsOneWidget);
    expect(labelOf(tester, '1'), contains(i18n.railEstimatedArrive('09:40')));

    await show(tester, [_train('1', '08:30', '09:30')]);
    expect(find.textContaining('預計'), findsNothing);
  });

  testWidgets('a train that has left is quieter, a late one still counts', (
    tester,
  ) async {
    await show(tester, [
      _train('1', '07:00', '08:00'),
      _train('2', '07:55', '09:00', delay: 10),
      _train('3', '08:30', '09:30'),
    ]);
    final quiet = AppTheme.inkTertiary(scheme(tester).brightness);

    expect(style(tester, '07:00').color, quiet);
    expect(style(tester, '07:55').color, scheme(tester).onSurface);
  });

  testWidgets('a past train and a suspended one each go quiet', (tester) async {
    await show(tester, [
      _train('101', '07:00', '07:35'),
      _train('103', '08:30', '09:35', suspended: true),
      _train('104', '08:40', '10:05'),
    ]);
    final scheme0 = scheme(tester);
    final quiet = AppTheme.inkTertiary(scheme0.brightness);

    expect(style(tester, '07:35').color, quiet);
    expect(style(tester, '09:35').color, quiet);
    expect(style(tester, '10:05').color, scheme0.onSurface);
    expect(style(tester, '101').color, quiet);
    expect(style(tester, '103').color, quiet);
    expect(style(tester, '104').color, scheme0.onSurfaceVariant);
  });

  testWidgets('the arrival note is small, red only for an estimate', (
    tester,
  ) async {
    await show(tester, [
      _train('101', '08:30', '09:30', delay: 10),
      _train('102', '23:06', '00:30'),
    ]);

    final estimate = style(tester, i18n.railEstimatedArrive('09:40'));
    expect(estimate.fontSize, 11);
    expect(estimate.color, scheme(tester).error);
    final nextDay = style(tester, i18n.railNextDayMark);
    expect(nextDay.fontSize, 11);
    expect(nextDay.color, scheme(tester).onSurfaceVariant);
  });

  testWidgets('a train still ahead of the minute hand has not left', (
    tester,
  ) async {
    await show(tester, [
      _train('101', '08:20', '08:50'),
      _train('102', '08:25', '09:35', delay: 10),
      _train('103', '09:10', '10:05'),
    ], at: DateTime(2030, 1, 2, 8, 30));
    final onSurface = scheme(tester).onSurface;

    expect(
      style(tester, '08:20').color,
      AppTheme.inkTertiary(scheme(tester).brightness),
    );
    expect(style(tester, '08:25').color, onSurface);
    expect(style(tester, '09:10').color, onSurface);
  });

  testWidgets('another day has no train that has left', (tester) async {
    await show(tester, [
      _train('101', '07:00', '08:00'),
      _train('102', '09:00', '10:00'),
    ], date: '2030-01-03');

    expect(style(tester, '07:00').color, scheme(tester).onSurface);
  });

  testWidgets('an arrival estimate wraps past midnight, early gives none', (
    tester,
  ) async {
    await show(tester, [
      _train('101', '23:30', '23:50', delay: 25),
      _train('102', '08:30', '09:30', delay: -5),
    ]);

    expect(find.text(i18n.railEstimatedArrive('00:15')), findsOneWidget);
    expect(find.textContaining('預計'), findsOneWidget);
  });

  testWidgets('the empty-state actions ask again for the same trip', (
    tester,
  ) async {
    await showState(
      tester,
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
      args: const RailRouteArgs(
        system: RailSystem.tra,
        originName: '台北',
        originId: '1000',
        destName: '台中',
        destId: '3300',
        date: null,
        isDeparture: true,
        submit: false,
      ),
    );
    RailTimetableRequested last() =>
        rail.events.whereType<RailTimetableRequested>().last;
    expect(rail.events, isEmpty);

    await tester.tap(find.text(i18n.railTomorrowFirst));
    await tester.pump();
    expect(last().date, '2030-01-03');
    expect(last().cutoffMinutes, 0);
    expect(last().isDeparture, isTrue);
    expect((last().origin.name, last().destination.name), ('台北', '台中'));

    await tester.tap(find.text(i18n.railEarlierHour));
    await tester.pump();
    expect(last().date, '2030-01-02');
    expect(last().cutoffMinutes, 23 * 60);
    expect((last().origin.name, last().destination.name), ('台北', '台中'));

    await tester.tap(find.text(i18n.railSwapDirection));
    await tester.pump();
    expect((last().origin.name, last().destination.name), ('台中', '台北'));
    expect((last().origin.id, last().destination.id), ('3300', '1000'));
  });

  testWidgets('the pill reopens the query sheet once a query was asked', (
    tester,
  ) async {
    await showState(
      tester,
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);

    await tester.tap(find.text(i18n.railTomorrowFirst));
    await tester.pump();
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    final controller = tester
        .widget<Sheet>(find.byType(Sheet).first)
        .controller!;
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      controller.metrics!.offset,
      closeTo(
        controller.metrics!.viewportSize.height * AppSheetSnap.halfFrac,
        1,
      ),
    );
  });

  testWidgets('the empty state centres above the peeked sheet', (
    tester,
  ) async {
    await showState(
      tester,
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );

    final padding = tester
        .widget<Padding>(
          find
              .descendant(
                of: find.byType(SliverFillRemaining),
                matching: find.byType(Padding),
              )
              .first,
        )
        .padding;
    expect(padding.vertical, greaterThan(0));
    expect(
      (padding as EdgeInsets).bottom,
      tester.view.physicalSize.height /
          tester.view.devicePixelRatio *
          AppSheetSnap.peekFrac,
    );
  });

  testWidgets('an empty result offers the way forward', (tester) async {
    await showState(
      tester,
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );

    expect(find.text(i18n.railNoTrains), findsOneWidget);
    expect(find.text(i18n.railTomorrowFirst), findsOneWidget);
    expect(find.text(i18n.railEarlierHour), findsOneWidget);
    expect(find.text(i18n.railSwapDirection), findsOneWidget);

    for (final label in [
      i18n.railTomorrowFirst,
      i18n.railEarlierHour,
      i18n.railSwapDirection,
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
  });
}
