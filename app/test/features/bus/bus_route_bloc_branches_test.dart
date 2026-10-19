import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/firebase_telemetry.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/firebase_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';

import '../../support/helpers/in_memory_reminders_store.dart';

const _fare = BusFareInfo(
  pricingType: 1,
  isFreeBus: false,
  sectionFaresJson: [],
  stageFaresJson: [],
  odFaresJson: [],
);

const _daily = BusDailyTimetable();

class _Bus extends BusRepository {
  _Bus({this.fare, this.daily, this.staticFails = false});
  final BusFareInfo? fare;
  final BusDailyTimetable? daily;
  final bool staticFails;

  @override
  Future<BusRouteViewModel> routeStatic(String subRouteUid) async {
    if (staticFails) throw const OfflineError();
    return BusRouteViewModel(
      subRouteUid: subRouteUid,
      routeName: '307',
      subRouteName: '307',
      departureStopName: 'A',
      destinationStopName: 'B',
      city: 'Taipei',
      headsignGo: 'B',
      headsignReturn: 'A',
      fare: fare,
    );
  }

  @override
  Stream<List<BusStopEtaViewModel>> routeEta(String subRouteUid) =>
      const Stream.empty();

  @override
  Future<BusDailyTimetable> routeDaily(String subRouteUid) async {
    final d = daily;
    if (d == null) throw StateError('daily unavailable');
    return d;
  }
}

class _Firebase extends FirebaseRepository {
  _Firebase({this.fail = false});
  final bool fail;
  final created = Completer<void>();

  @override
  Future<ArrivalReminderReceipt> createArrivalReminder({
    required String routeType,
    required String routeKey,
    required String stopKey,
    required String direction,
    required int leadMinutes,
    required DateTime expiresAt,
    String plate = '',
    String alightEvent = '',
  }) async {
    await created.future;
    if (fail) throw StateError('grpc down');
    return const ArrivalReminderReceipt(reminderId: 'srv-1');
  }
}

class _SpyBloc extends BusRouteBloc {
  _SpyBloc({
    required super.busRepository,
    super.firebaseRepository,
    super.telemetry,
    super.reportError,
    super.autoStart,
    RemindersRepository? reminders,
  }) : super(
         subRouteUid: 'R',
         remindersRepository:
             reminders ?? RemindersRepository(store: InMemoryRemindersStore()),
       );

  final events = <BusRouteEvent>[];

  @override
  void onEvent(BusRouteEvent event) {
    events.add(event);
    super.onEvent(event);
  }
}

BusStopEtaViewModel _eta(String uid, int sequence) => BusStopEtaViewModel(
  stopUid: uid,
  direction: 0,
  sequence: sequence,
  estimateSeconds: 60,
  nextBusTime: '',
  stopStatus: 0,
  vehiclePlates: const [],
);

void main() {
  for (final (daily, fare) in [
    (null, null),
    (null, _fare),
    (_daily, null),
    (_daily, _fare),
  ]) {
    test('details load publishes iff something loaded '
        '(daily=${daily != null}, fare=${fare != null})', () async {
      final bloc = _SpyBloc(
        busRepository: _Bus(fare: fare, daily: daily),
      );
      addTearDown(bloc.close);

      await bloc.stream.firstWhere((s) => !s.loading && s.route != null);
      await pumpEventQueue();

      final updates = bloc.events.whereType<BusRouteDetailsUpdated>().toList();
      if (daily == null && fare == null) {
        expect(updates, isEmpty);
      } else {
        expect(updates.single.daily, daily);
        expect(updates.single.fare, fare);
        expect(bloc.state.daily, daily);
      }
    });
  }

  test('a daily timetable failure is reported with its own error', () async {
    final reported = <Object>[];
    final bloc = _SpyBloc(
      busRepository: _Bus(),
      reportError: (e, _) => reported.add(e),
    );
    addTearDown(bloc.close);

    await bloc.stream.firstWhere((s) => !s.loading && s.route != null);
    await pumpEventQueue();

    expect(reported.single, isA<StateError>());
    expect((reported.single as StateError).message, 'daily unavailable');
  });

  test('an empty ETA frame never wipes a populated map', () async {
    final bloc = _SpyBloc(busRepository: _Bus(), autoStart: false);
    addTearDown(bloc.close);

    bloc.add(BusRouteEtaUpdated({'seq:0:1': _eta('A', 1)}));
    await pumpEventQueue();
    final stamp = bloc.state.updatedAt;
    expect(bloc.state.etaMap.keys, ['seq:0:1']);

    bloc.add(const BusRouteEtaUpdated({}));
    await pumpEventQueue();

    expect(bloc.state.etaMap.keys, ['seq:0:1']);
    expect(bloc.state.updatedAt, stamp);
  });

  test('a first empty ETA frame still stamps the freshness time', () async {
    final bloc = _SpyBloc(busRepository: _Bus(), autoStart: false);
    addTearDown(bloc.close);

    bloc.add(const BusRouteEtaUpdated({}));
    await pumpEventQueue();

    expect(bloc.state.updatedAt, isNotNull);
  });

  test('arming marks the stop pending until the server answers', () async {
    final firebase = _Firebase();
    final logged = <(String, Map<String, Object>?)>[];
    final bloc = _SpyBloc(
      busRepository: _Bus(),
      firebaseRepository: firebase,
      telemetry: FirebaseTelemetry(
        enabled: true,
        logEvent: (name, parameters) async => logged.add((name, parameters)),
      ),
      autoStart: false,
    );
    addTearDown(bloc.close);

    bloc.add(
      const BusRoutePinnedReminderArmed(
        stopUid: 'S',
        plate: 'P',
        event: AlightEvent.alight,
      ),
    );
    await pumpEventQueue();
    expect(bloc.state.reminders, {'S': 'pending'});
    expect(logged, isEmpty);

    firebase.created.complete();
    await pumpEventQueue();

    expect(bloc.state.reminders, {'S': 'srv-1'});
    expect(logged, hasLength(1));
    expect(logged.single.$1, 'arrival_reminder_changed');
    expect(logged.single.$2, {
      'route_type': 'bus',
      'route_key': 'R',
      'enabled': 1,
      'lead_minutes': 1,
    });
  });

  test('a rejected arm is reported and its pending mark removed', () async {
    final firebase = _Firebase(fail: true);
    final reported = <Object>[];
    final bloc = _SpyBloc(
      busRepository: _Bus(),
      firebaseRepository: firebase,
      reportError: (e, _) => reported.add(e),
      autoStart: false,
    );
    addTearDown(bloc.close);

    bloc.add(
      const BusRoutePinnedReminderArmed(
        stopUid: 'S',
        plate: 'P',
        event: AlightEvent.alight,
      ),
    );
    await pumpEventQueue();
    expect(bloc.state.reminders, {'S': 'pending'});

    firebase.created.complete();
    await pumpEventQueue();

    expect(bloc.state.reminders, isEmpty);
    expect((reported.single as StateError).message, 'grpc down');
  });

  test('stream recovery clears the stream error', () async {
    final bloc = _SpyBloc(busRepository: _Bus(), autoStart: false);
    addTearDown(bloc.close);

    bloc.add(const BusRouteStreamFailed(OfflineError()));
    await pumpEventQueue();
    expect(bloc.state.error, isA<OfflineError>());

    bloc.add(const BusRouteStreamRecovered());
    await pumpEventQueue();

    expect(bloc.state.error, isNull);
  });

  test('a direction toggle switches the shown direction', () async {
    final bloc = _SpyBloc(busRepository: _Bus(), autoStart: false);
    addTearDown(bloc.close);
    expect(bloc.state.direction, 0);

    bloc.add(const BusRouteDirectionToggled(1));
    await pumpEventQueue();

    expect(bloc.state.direction, 1);
  });

  test('starting shows loading and the stored reminders at once', () async {
    final reminders = RemindersRepository(store: InMemoryRemindersStore());
    await reminders.put(
      'R',
      'STOP',
      'rem-1',
      DateTime.now().add(const Duration(hours: 1)),
    );
    final states = <bool>[];
    final bloc = _SpyBloc(
      busRepository: _Bus(),
      reminders: reminders,
      autoStart: false,
    );
    addTearDown(bloc.close);
    bloc.stream.listen((s) => states.add(s.loading));

    bloc.add(const BusRouteStarted());
    await bloc.stream.first;

    expect(bloc.state.loading, isTrue);
    expect(bloc.state.reminders, {'STOP': 'rem-1'});
    await bloc.stream.firstWhere((s) => !s.loading);
    expect(states.first, isTrue);
  });

  test('a restart drops the previous error while it reloads', () async {
    final bloc = _SpyBloc(busRepository: _Bus(), autoStart: false);
    addTearDown(bloc.close);
    bloc.add(const BusRouteStreamFailed(OfflineError()));
    await pumpEventQueue();
    expect(bloc.state.error, isNotNull);

    bloc.add(const BusRouteStarted());
    final loading = await bloc.stream.firstWhere((s) => s.loading);

    expect(loading.error, isNull);
  });

  test(
    'a failed route load settles with the error and stops loading',
    () async {
      final bloc = _SpyBloc(busRepository: _Bus(staticFails: true));
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere((s) => s.error != null);

      expect(state.loading, isFalse);
      expect(state.error, isA<OfflineError>());
      expect(state.route, isNull);
    },
  );
}
