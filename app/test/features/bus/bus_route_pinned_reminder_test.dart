import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/data/models/firebase_models.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';

import '../../support/helpers/in_memory_reminders_store.dart';

class _CapturingFirebaseRepository extends FirebaseRepository {
  _CapturingFirebaseRepository({this.failCreate = false});
  final bool failCreate;
  String? capturedPlate;
  int? capturedLeadMinutes;
  String? capturedStopKey;
  String? capturedAlightEvent;

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
    capturedPlate = plate;
    capturedAlightEvent = alightEvent;
    capturedLeadMinutes = leadMinutes;
    capturedStopKey = stopKey;
    if (failCreate) throw Exception('grpc down');
    return const ArrivalReminderReceipt(reminderId: 'srv-pin-1');
  }
}

void main() {
  test(
    'pinned reminder arms with the plate, one-stop lead, and persists',
    () async {
      final fake = _CapturingFirebaseRepository();
      final reminders = RemindersRepository(store: InMemoryRemindersStore());
      final bloc = BusRouteBloc(
        subRouteUid: 'TPE1234',
        autoStart: false,
        firebaseRepository: fake,
        remindersRepository: reminders,
      );
      addTearDown(bloc.close);

      bloc.add(
        const BusRoutePinnedReminderArmed(
          stopUid: 'TRIGGER',
          plate: 'KAA-1234',
          event: AlightEvent.alight,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.reminders['TRIGGER'], 'srv-pin-1');
      expect(fake.capturedPlate, 'KAA-1234');
      expect(fake.capturedLeadMinutes, 1);
      expect(fake.capturedStopKey, 'TRIGGER');
      // Mirrored locally like the bell path so it survives restart.
      expect(reminders.active('TPE1234'), {'TRIGGER': 'srv-pin-1'});
    },
  );

  test('a failed create rolls the pinned reminder back', () async {
    final bloc = BusRouteBloc(
      subRouteUid: 'TPE1234',
      autoStart: false,
      firebaseRepository: _CapturingFirebaseRepository(failCreate: true),
      remindersRepository: RemindersRepository(
        store: InMemoryRemindersStore(),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(
      const BusRoutePinnedReminderArmed(
        stopUid: 'TRIGGER',
        plate: 'KAA-1234',
        event: AlightEvent.alight,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(bloc.state.reminders.containsKey('TRIGGER'), isFalse);
  });

  test('re-arming an armed stop leaves the existing reminder', () async {
    final fake = _CapturingFirebaseRepository();
    final bloc = BusRouteBloc(
      subRouteUid: 'TPE1234',
      autoStart: false,
      firebaseRepository: fake,
      remindersRepository: RemindersRepository(
        store: InMemoryRemindersStore(),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(
      const BusRoutePinnedReminderArmed(
        stopUid: 'TRIGGER',
        plate: 'KAA-1',
        event: AlightEvent.alight,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    bloc.add(
      const BusRoutePinnedReminderArmed(
        stopUid: 'TRIGGER',
        plate: 'ZZZ-9',
        event: AlightEvent.alight,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Still the first plate's reminder; the second arm was a no-op.
    expect(bloc.state.reminders['TRIGGER'], 'srv-pin-1');
    expect(fake.capturedPlate, 'KAA-1');
  });
}
