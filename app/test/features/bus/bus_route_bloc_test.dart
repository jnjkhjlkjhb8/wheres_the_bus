import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';

import '../../support/helpers/in_memory_reminders_store.dart';

class _FailedDaily extends BusRepository {
  _FailedDaily(this.fare);
  final BusFareInfo? fare;

  @override
  Future<BusRouteViewModel> routeStatic(String subRouteUid) async =>
      BusRouteViewModel(
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

  @override
  Stream<List<BusStopEtaViewModel>> routeEta(String subRouteUid) =>
      const Stream.empty();

  @override
  Future<BusDailyTimetable> routeDaily(String subRouteUid) async =>
      throw StateError('daily unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final withFare in [false, true]) {
    test(
      'a missing daily timetable preserves the static route (fare=$withFare)',
      () async {
        final fare = withFare
            ? const BusFareInfo(
                pricingType: 1,
                isFreeBus: false,
                sectionFaresJson: [],
                stageFaresJson: [],
                odFaresJson: [],
              )
            : null;
        final bloc = BusRouteBloc(
          subRouteUid: 'R',
          busRepository: _FailedDaily(fare),
          remindersRepository: RemindersRepository(
            store: InMemoryRemindersStore(),
          ),
        );
        addTearDown(bloc.close);
        await bloc.stream.firstWhere(
          (state) => !state.loading && state.route != null,
        );
        await pumpEventQueue();
        expect(bloc.state.route!.routeName, '307');
        expect(bloc.state.fare, fare);
        expect(bloc.state.daily, isNull);
        expect(bloc.state.error, isNull);
      },
    );
  }

  test('BusRouteStreamFailed sets AppError', () async {
    final bloc = BusRouteBloc(subRouteUid: 'TEST', autoStart: false);
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emits(
        isA<BusRouteState>().having(
          (s) => s.error,
          'error',
          isA<OfflineError>(),
        ),
      ),
    );

    bloc.add(const BusRouteStreamFailed(OfflineError()));
    await next;
  });
}
