import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_event.dart';
import 'package:wheres_the_bus/features/go/bloc/trip_state.dart';

class TripBloc extends Bloc<TripEvent, TripState> {
  TripBloc() : super(const TripState()) {
    on<TripStarted>(
      (event, emit) => emit(
        TripState(route: event.route, activeLegIndex: 0, activeStopIndex: 0),
      ),
    );
    on<StopArrived>(_onStopArrived);
    on<WalkStepAdvanced>(_onWalkStepAdvanced);
    on<TripEnded>((_, emit) => emit(const TripState()));
    on<TripRoutesRefreshed>(_onRoutesRefreshed);
  }

  void _onStopArrived(StopArrived event, Emitter<TripState> emit) {
    if (!state.active) return;
    // Each leg starts at its first walk step; the coordinator advances it.
    emit(
      TripState(
        route: state.route,
        activeLegIndex: event.legIndex,
        activeStopIndex: event.stopIndex,
      ),
    );
  }

  void _onWalkStepAdvanced(WalkStepAdvanced event, Emitter<TripState> emit) {
    if (!state.active) return;
    emit(
      TripState(
        route: state.route,
        activeLegIndex: state.activeLegIndex,
        activeStopIndex: state.activeStopIndex,
        activeWalkStepIndex: event.index,
      ),
    );
  }

  void _onRoutesRefreshed(TripRoutesRefreshed event, Emitter<TripState> emit) {
    final route = state.route;
    if (route == null) return;
    emit(
      TripState(
        route: route.refreshedFrom(event.routes),
        activeLegIndex: state.activeLegIndex,
        activeStopIndex: state.activeStopIndex,
        activeWalkStepIndex: state.activeWalkStepIndex,
      ),
    );
  }
}
