import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_service_marks.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_track_bell.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';
import '../../support/helpers/remote_assets.dart';

const stops = [
  RailTrainStop(name: '台北', arrive: '', depart: '08:00'),
  RailTrainStop(name: '板橋', arrive: '08:10', depart: '08:11'),
  RailTrainStop(name: '桃園', arrive: '08:25', depart: '08:30'),
  RailTrainStop(name: '新竹', arrive: '09:00', depart: '09:01'),
  RailTrainStop(name: '台中', arrive: '10:00', depart: ''),
];

RailFareQuote quote(int price) => RailFareQuote.tra(
  fares: [TraFare(ticketType: '成自', price: price)],
  trainType: '自強',
);

class _TrainBloc extends RailTrainBloc {
  _TrainBloc(RailTrainState state)
    : super(type: '自強', trainNo: '123', date: '2030-01-02') {
    emit(state);
  }
  final events = <RailTrainEvent>[];
  @override
  void add(RailTrainEvent event) => events.add(event);
  void show(RailTrainState state) => emit(state);
}

class _JourneyBloc extends JourneySessionBloc {
  _JourneyBloc() : super(liveActivityEnabled: () => false);
  final events = <JourneySessionEvent>[];
  @override
  void add(JourneySessionEvent event) => events.add(event);
  void show(JourneySessionState state) => emit(state);
}

class _Favorites implements FavoritesRepository {
  @override
  bool get isReady => true;
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  Stream<void> changes() => const Stream.empty();
  @override
  List<Favorite> all() => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(seedRemoteAssets);

  Future<(_TrainBloc, _JourneyBloc)> pumpTrain(
    WidgetTester tester, {
    RailTrainState? state,
    String? origin,
    String? destination,
    String type = '自強',
    String date = '2030-01-02',
    List<RailServiceMark> marks = const [],
    String remark = '',
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final train = _TrainBloc(
      state ??
          const RailTrainState(status: RailTrainStatus.loaded, stops: stops),
    );
    final journey = _JourneyBloc();
    final favorites = FavoritesBloc(_Favorites(), ValueNotifier(true));
    addTearDown(train.close);
    addTearDown(journey.close);
    addTearDown(favorites.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<JourneySessionBloc>.value(value: journey),
          BlocProvider<FavoritesBloc>.value(value: favorites),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          theme: AppTheme.light,
          home: RailTrainScreen(
            type: type,
            trainNo: '123',
            date: date,
            bloc: train,
            userOrigin: origin,
            userDest: destination,
            marks: marks,
            remark: remark,
            clock: clock ?? DateTime.now,
          ),
        ),
      ),
    );
    await tester.pump();
    return (train, journey);
  }

  Future<void> disposeTrain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'timetable keeps endpoints, elapsed times and long dwells aligned',
    (tester) async {
      await pumpTrain(tester, origin: '板橋', destination: '台中');
      expect(find.text('08:00'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);
      expect(find.text('停 5 分'), findsOneWidget);
      expect(find.text('上車'), findsOneWidget);
      expect(find.text('下車'), findsOneWidget);
      expect(find.byType(TimelineSpine), findsNWidgets(5));
      await disposeTrain(tester);
    },
  );

  testWidgets(
    'segment information labels both the selected fare and full run',
    (tester) async {
      await pumpTrain(
        tester,
        origin: '板橋',
        destination: '新竹',
        state: RailTrainState(
          status: RailTrainStatus.loaded,
          stops: stops,
          fullFare: quote(300),
          userFare: quote(100),
        ),
        marks: const [RailServiceMark.bike],
        remark: '不停靠苗栗',
      );
      await tester.tap(find.text('詳細資訊'));
      await tester.pumpAndSettle();
      expect(find.text('板橋 → 新竹'), findsOneWidget);
      expect(find.textContaining('300'), findsWidgets);
      expect(find.text('不停靠苗栗'), findsOneWidget);
      await disposeTrain(tester);
    },
  );

  testWidgets(
    'unknown segment uses full run and a missing segment fare stays explicit',
    (tester) async {
      final (train, _) = await pumpTrain(
        tester,
        origin: '板橋',
        destination: '新竹',
        state: RailTrainState(
          status: RailTrainStatus.loaded,
          stops: stops,
          fullFare: quote(300),
        ),
      );
      await tester.tap(find.text('詳細資訊'));
      await tester.pumpAndSettle();
      expect(find.textContaining('板橋'), findsWidgets);
      expect(find.textContaining('票價'), findsWidgets);
      train.show(
        const RailTrainState(status: RailTrainStatus.loaded, stops: stops),
      );
      await tester.pump();
      await disposeTrain(tester);
    },
  );

  testWidgets(
    'searched destination confirms, repicks and starts a scoped rail reminder',
    (tester) async {
      final (_, journey) = await pumpTrain(
        tester,
        origin: '板橋',
        destination: '台中',
      );
      await tester.tap(find.byType(AlightTrackBell));
      await tester.pump();
      final confirm = tester.widget<AlightConfirmBar>(
        find.byType(AlightConfirmBar),
      );
      expect(confirm.targetName, '台中');
      expect(confirm.fromSearch, isTrue);
      confirm.onLeadChanged(1);
      await tester.pump();
      tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).onStart();
      await tester.pump();
      final start = journey.events.single as JourneyStarted;
      expect(start.trackOnly, isTrue);
      expect(start.leadStops, 1);
      expect(start.legs.single.boardStop, '板橋');
      expect(start.legs.single.alightStop, '台中');
      expect(start.legs.single.railSchedule.length, 4);
      journey.show(
        JourneySessionState(
          phase: JourneyPhase.waiting,
          trackOnly: true,
          legs: start.legs,
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(AlightTrackBell));
      await tester.pump();
      final manage = tester.widget<AlightManageBar>(
        find.byType(AlightManageBar),
      );
      expect(manage.targetName, '台中');
      manage.onClose();
      await tester.pump();
      await tester.tap(find.byType(AlightTrackBell));
      await tester.pump();
      tester.widget<AlightManageBar>(find.byType(AlightManageBar)).onCancel();
      expect(journey.events.last, isA<JourneyCancelled>());
      await disposeTrain(tester);
    },
  );

  testWidgets(
    'manual reminder allows only stops after boarding and can be cancelled',
    (tester) async {
      await pumpTrain(tester, origin: '板橋');
      await tester.tap(find.byType(AlightTrackBell));
      await tester.pump();
      await tester.tap(find.text('新竹'));
      await tester.pump();
      final confirm = tester.widget<AlightConfirmBar>(
        find.byType(AlightConfirmBar),
      );
      expect(confirm.targetName, '新竹');
      expect(confirm.fromSearch, isFalse);
      confirm.onRepick!();
      await tester.pump();
      await tester.tap(find.byType(AlightTrackBell));
      await tester.pump();
      expect(find.byType(AlightConfirmBar), findsNothing);
      await disposeTrain(tester);
    },
  );

  testWidgets(
    'loading, empty and retry states render without booking actions',
    (tester) async {
      final (train, _) = await pumpTrain(tester, state: const RailTrainState());
      expect(find.text('訂購'), findsNothing);
      train.show(const RailTrainState(status: RailTrainStatus.empty));
      await tester.pump();
      expect(find.textContaining('123'), findsWidgets);
      train.show(
        const RailTrainState(
          status: RailTrainStatus.error,
          error: OfflineError(),
        ),
      );
      await tester.pump();
      tester.widget<ErrorStateView>(find.byType(ErrorStateView)).onRetry!();
      expect(train.events.single, isA<RailTrainStarted>());
      await disposeTrain(tester);
    },
  );

  testWidgets('live delay displays the observation freshness', (tester) async {
    final observed = DateTime(2030, 1, 2, 8, 20);
    await pumpTrain(
      tester,
      state: RailTrainState(
        status: RailTrainStatus.loaded,
        stops: stops,
        liveDelayMinutes: 2,
        delayUpdatedAt: observed,
      ),
      clock: () => observed,
    );
    final stamp = tester.widget<FreshnessStamp>(find.byType(FreshnessStamp));
    expect(stamp.at, observed);
    await disposeTrain(tester);
  });

  testWidgets(
    'boarding at the final stop hides elapsed column and reminder bell',
    (tester) async {
      await pumpTrain(tester, origin: '台中', destination: '台中', type: '高鐵');
      expect(find.byType(AlightTrackBell), findsNothing);
      expect(find.text('歷時'), findsNothing);
      await tester.tap(find.text('詳細資訊'));
      await tester.pumpAndSettle();
      await disposeTrain(tester);
    },
  );
  testWidgets('past stations expand while the current stop stays visible', (
    tester,
  ) async {
    await pumpTrain(tester, clock: () => DateTime(2030, 1, 2, 8, 40));
    expect(find.text('台北'), findsNothing);
    expect(find.text('桃園'), findsOneWidget);
    expect(find.byType(TimelineSpine), findsNWidgets(3));
    await tester.tap(find.textContaining('已過 2 站'));
    await tester.pump();
    expect(find.text('台北'), findsOneWidget);
    expect(find.byType(TimelineSpine), findsNWidgets(5));
    await disposeTrain(tester);
  });

  testWidgets('a full-run fare has no redundant secondary segment label', (
    tester,
  ) async {
    await pumpTrain(
      tester,
      origin: '台北',
      destination: '台中',
      state: RailTrainState(
        status: RailTrainStatus.loaded,
        stops: stops,
        fullFare: quote(300),
        userFare: quote(300),
      ),
    );
    await tester.tap(find.text('詳細資訊'));
    await tester.pumpAndSettle();
    expect(find.text('台北 → 台中'), findsWidgets);
    expect(find.text(r'$300'), findsOneWidget);
    expect(find.textContaining('全程：'), findsNothing);
    await disposeTrain(tester);
  });

  group('railTrackSchedule', () {
    List<String> names(String board, String alight) => [
      for (final s in railTrackSchedule(
        stops,
        '2030-01-02',
        board: board,
        alight: alight,
      ))
        s.name,
    ];

    test('runs from the boarding stop to the alighting stop', () {
      expect(names('板橋', '新竹'), ['板橋', '桃園', '新竹']);
    });

    test('boarding and alighting at one stop is no trip', () {
      expect(names('板橋', '板橋'), isEmpty);
    });

    test('an alight before the board, or an unknown stop, is no trip', () {
      expect(names('新竹', '板橋'), isEmpty);
      expect(names('不存在', '板橋'), isEmpty);
    });

    test('an unreadable time drops the whole schedule', () {
      expect(
        railTrackSchedule(
          const [
            RailTrainStop(name: '甲', arrive: '', depart: 'bad'),
            RailTrainStop(name: '乙', arrive: '08:10', depart: ''),
          ],
          '2030-01-02',
          board: '甲',
          alight: '乙',
        ),
        isEmpty,
      );
    });
  });

  testWidgets('the header dates the train month/day with its weekday', (
    tester,
  ) async {
    await pumpTrain(tester);

    expect(find.textContaining('01/02 (三)'), findsWidgets);
    await disposeTrain(tester);
  });

  group('booking bar fare', () {
    final i18n = lookupAppI18n(const Locale('zh'));

    Future<void> withQuote(WidgetTester tester, RailFareQuote? fare) =>
        pumpTrain(
          tester,
          state: RailTrainState(
            status: RailTrainStatus.loaded,
            stops: stops,
            userFare: fare,
          ),
        );

    testWidgets('quotes the price quietly beside the action', (tester) async {
      await withQuote(tester, quote(100));

      expect(find.text(i18n.railBook), findsOneWidget);
      final price = tester.widget<Text>(find.text(r'NT$ 100'));
      final cs = Theme.of(tester.element(find.text(r'NT$ 100'))).colorScheme;
      expect(price.style!.fontSize, 14);
      expect(price.style!.color, cs.onPrimary.withValues(alpha: 0.82));
      await disposeTrain(tester);
    });

    testWidgets('a free or missing fare shows no price', (tester) async {
      await withQuote(tester, quote(0));
      expect(find.textContaining(r'NT$'), findsNothing);

      await withQuote(tester, null);
      expect(find.textContaining(r'NT$'), findsNothing);
      await disposeTrain(tester);
    });
  });
}
