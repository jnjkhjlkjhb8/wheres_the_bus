import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';

final now = DateTime(2030, 1, 2, 8);

class _Rail extends RailBloc {
  _Rail(RailState initial) {
    emit(initial);
  }
  final events = <RailEvent>[];
  @override
  void add(RailEvent event) => events.add(event);
  void show(RailState next) => emit(next);
}

TraTimetableItem train(
  String number,
  String depart,
  String arrive, {
  bool suspended = false,
  bool added = false,
}) => TraTimetableItem(
  trainNo: number,
  trainType: '自強',
  departureTime: depart,
  arrivalTime: arrive,
  travelMinutes: 0,
  delayMinutes: 0,
  hasBike: true,
  hasDiningCar: true,
  isDisabledFriendly: true,
  hasBreastfeeding: true,
  remark: '注意月台',
  isSuspended: suspended,
  isAddedService: added,
);

RailTimetableLoaded loaded({String date = '2030-01-02'}) => RailTimetableLoaded(
  system: RailSystem.tra,
  originName: '台北',
  destName: '台中',
  date: date,
  traItems: [
    train('1', '07:00', '08:00'),
    train('2', '08:05', '09:00', suspended: true),
    train('3', 'bad', 'x'),
    train('4', '2030-01-02T08:30:00+08:00', '09:30:00'),
    train('5', '23:30', '01:00', added: true),
    train('6', 'x:y', 'z:q'),
  ],
  delays: const {'1': 2},
);

void main() {
  Future<_Rail> show(
    WidgetTester tester,
    RailState state, {
    RailRouteArgs? args,
  }) async {
    tester.view.physicalSize = const Size(430, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = _Rail(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: RailScreen(bloc: bloc, clock: () => now, args: args),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return bloc;
  }

  Future<void> dispose(WidgetTester tester, _Rail bloc) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(bloc.isClosed, isFalse);
    expect(tester.takeException(), isNull);
  }

  testWidgets('bare and incomplete links retain an editable query', (
    tester,
  ) async {
    final bloc = await show(tester, const RailInitial());
    expect(bloc.events, isEmpty);
    final query = tester.widget<RailQuerySheetContent>(
      find.byType(RailQuerySheetContent),
    );
    expect(query.preset, isNull);
    query.onSystemChanged!(RailSystem.thsr);
    expect(bloc.events.last, isA<RailSystemChanged>());
    await tester.pump();
    await dispose(tester, bloc);

    final seeded = await show(
      tester,
      const RailInitial(),
      args: RailRouteArgs.from({
        'from': '台北',
        'fromId': '1000',
        'to': '台北',
        'submit': '1',
      }),
    );
    expect(seeded.events, isEmpty);
    final preset = tester
        .widget<RailQuerySheetContent>(find.byType(RailQuerySheetContent))
        .preset!;
    expect(preset.destName, '');
    expect(preset.date, now);
    await dispose(tester, seeded);
  });

  testWidgets('submitted links keep ids, cutoff and retry semantics', (
    tester,
  ) async {
    final bloc = await show(
      tester,
      const RailInitial(),
      args: RailRouteArgs.from({
        'from': '台北',
        'fromId': '1000',
        'to': '台中',
        'toId': '3300',
        'date': '2030-01-02T09:20:00',
        'dep': '0',
        'submit': '1',
      }),
    );
    final request = bloc.events.single as RailTimetableRequested;
    expect(
      (
        request.origin.id,
        request.destination.id,
        request.cutoffMinutes,
        request.isDeparture,
      ),
      ('1000', '3300', 560, false),
    );
    bloc.show(const RailError(OfflineError()));
    await tester.pump();
    await tester.pump();
    tester.widget<ErrorStateView>(find.byType(ErrorStateView)).onRetry!();
    expect(bloc.events, hasLength(2));
    final query = tester.widget<RailQuerySheetContent>(
      find.byType(RailQuerySheetContent),
    );
    query.onSubmit(
      RailOdQuerySubmission(
        system: RailSystem.thsr,
        originName: '台北',
        destName: '左營',
        date: now,
        isDeparture: true,
      ),
    );
    expect(
      (bloc.events.last as RailTimetableRequested).system,
      RailSystem.thsr,
    );
    expect((bloc.events.last as RailTimetableRequested).origin.id, isNull);
    await tester.pump(const Duration(seconds: 1));
    await dispose(tester, bloc);
  });

  testWidgets('loaded rows qualify valid next trains and overnight durations', (
    tester,
  ) async {
    final bloc = await show(tester, loaded());
    expect(find.text('1時'), findsWidgets);
    expect(find.text('1時30分'), findsOneWidget);
    expect(find.text('30 分後'), findsOneWidget);
    expect(find.text('停駛'), findsWidgets);
    expect(find.text('0分'), findsWidgets);
    final scroll = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    await scroll.onRefresh();
    expect(bloc.events.last, isA<RailTimetableRequested>());
    bloc.show(loaded(date: '2030-01-03'));
    await tester.pump();
    await tester.pump();
    expect(find.text('30 分後'), findsNothing);
    await dispose(tester, bloc);
  });

  testWidgets('loading, empty and THSR rows remain distinct outcomes', (
    tester,
  ) async {
    final bloc = await show(
      tester,
      const RailTimetableLoading(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );
    bloc.show(
      const RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(RefreshIndicator), findsNothing);
    bloc.show(
      const RailTimetableLoaded(
        system: RailSystem.thsr,
        originName: '台北',
        destName: '左營',
        date: '2030-01-02',
        thsrItems: [
          ThsrTimetableItem(
            trainNo: '601',
            departureTime: '12:00',
            arrivalTime: '12:30',
            travelMinutes: 30,
            delayMinutes: 0,
            remark: '',
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('601'), findsOneWidget);
    expect(find.text('30分'), findsWidgets);
    await dispose(tester, bloc);
  });
}
