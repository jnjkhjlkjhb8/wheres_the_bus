import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_event.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_state.dart';

void main() {
  test('starts with no trip under way', () {
    final bloc = TripBloc();
    addTearDown(bloc.close);
    expect(bloc.state, const TripState());
    expect(bloc.state.active, isFalse);
  });

  test('a trip is active only with both a route and a leg', () {
    expect(const TripState(activeLegIndex: 0).active, isFalse);
    expect(TripState(route: _route('a')).active, isFalse);
    expect(TripState(route: _route('a'), activeLegIndex: 0).active, isTrue);
  });

  test('starting a trip makes its first leg active', () async {
    final bloc = TripBloc();
    addTearDown(bloc.close);
    final route = _route('a');

    bloc.add(TripStarted(route));
    await bloc.stream.first;

    expect(
      bloc.state,
      TripState(route: route, activeLegIndex: 0, activeStopIndex: 0),
    );
    expect(bloc.state.active, isTrue);
  });

  test('progress events update and the end clears the trip', () async {
    final bloc = TripBloc();
    addTearDown(bloc.close);
    final route = _route('a');

    bloc
      ..add(TripStarted(route))
      ..add(const WalkStepAdvanced(index: 2))
      ..add(const StopArrived(legIndex: 1, stopIndex: 3))
      ..add(const TripEnded());

    await expectLater(
      bloc.stream,
      emitsInOrder([
        TripState(route: route, activeLegIndex: 0, activeStopIndex: 0),
        TripState(
          route: route,
          activeLegIndex: 0,
          activeStopIndex: 0,
          activeWalkStepIndex: 2,
        ),
        // A new leg starts at its first walk step.
        TripState(route: route, activeLegIndex: 1, activeStopIndex: 3),
        const TripState(),
      ]),
    );
  });

  test('progress before a trip starts is ignored', () async {
    final bloc = TripBloc();
    addTearDown(bloc.close);

    bloc
      ..add(const StopArrived(legIndex: 1, stopIndex: 1))
      ..add(const WalkStepAdvanced(index: 1))
      ..add(TripRoutesRefreshed([_route('a')]));
    await pumpEventQueue();

    expect(bloc.state, const TripState());
  });

  test('a refresh swaps in the same itinerary and keeps progress', () async {
    final bloc = TripBloc();
    addTearDown(bloc.close);
    final withGeometry = _route('a', travelTime: 900);

    bloc
      ..add(TripStarted(_route('a')))
      ..add(const StopArrived(legIndex: 2, stopIndex: 1))
      ..add(const WalkStepAdvanced(index: 4))
      ..add(TripRoutesRefreshed([_route('b'), withGeometry]));
    await pumpEventQueue();

    expect(bloc.state.route, same(withGeometry));
    expect(bloc.state.activeLegIndex, 2);
    expect(bloc.state.activeStopIndex, 1);
    expect(bloc.state.activeWalkStepIndex, 4);
  });

  test('a new search cannot change the trip under way', () async {
    final bloc = TripBloc();
    addTearDown(bloc.close);
    final route = _route('a');

    bloc
      ..add(TripStarted(route))
      ..add(TripRoutesRefreshed([_route('b'), _route('c')]));
    await pumpEventQueue();

    expect(bloc.state.route, same(route));
  });
}

PlanRoute _route(String id, {int travelTime = 600}) => PlanRoute(
  travelTime: travelTime,
  startTime: '12:00',
  endTime: '12:10',
  transfers: 0,
  sections: const [],
  id: id,
);
