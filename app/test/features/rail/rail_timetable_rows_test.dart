import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

// 2030-01-02 08:00, so a 09:00 departure is exactly 60 minutes away.
final _now = DateTime(2030, 1, 2, 8);

class _Rail extends RailBloc {
  _Rail(RailState initial) {
    emit(initial);
  }

  @override
  void add(RailEvent event) {}
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

  Future<void> showState(
    WidgetTester tester,
    RailState state, {
    DateTime? at,
  }) async {
    tester.view.physicalSize = const Size(430, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = _Rail(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: RailScreen(bloc: bloc, clock: () => at ?? _now),
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

    expect(style(tester, '09:30').fontSize, 15);
    expect(style(tester, '1時').fontSize, 11);
    expect(style(tester, '1').fontSize, 12);
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
}
