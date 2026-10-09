import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_state.dart';

class MetroBloc extends Bloc<MetroEvent, MetroState> {
  MetroBloc({MrtRepository? repository})
    : _repository = repository ?? MrtRepository.instance,
      super(const MetroState()) {
    on<MetroStationTapped>(_onStationTapped);
    on<MetroStationDismissed>(_onStationDismissed);
    on<MetroJourneyMatrixLoaded>(_onMatrixLoaded);
  }

  final MrtRepository _repository;

  // Handlers run concurrently (no transformer), so tapping station B before
  // station A's matrix fetch resolves can otherwise let A's stale response
  // land last and clobber B's fresh one.
  var _generation = 0;

  Future<void> _onStationTapped(
    MetroStationTapped event,
    Emitter<MetroState> emit,
  ) async {
    final gen = ++_generation;
    emit(
      state.copyWith(
        activeStationId: event.stationId,
        clearMatrix: true,
        clearError: true,
      ),
    );
    try {
      final matrix = await _repository.journeyMatrix(event.stationId);
      if (gen != _generation) return;
      emit(
        state.copyWith(
          activeStationId: event.stationId,
          journeyMatrix: matrix,
          clearError: true,
        ),
      );
    } on Object catch (e, s) {
      if (gen != _generation) return;
      CrashReporter.record(e, s);
      emit(state.copyWith(error: AppError.from(e)));
    }
  }

  void _onStationDismissed(MetroStationDismissed _, Emitter<MetroState> emit) {
    emit(
      state.copyWith(clearStation: true, clearMatrix: true, clearError: true),
    );
  }

  void _onMatrixLoaded(
    MetroJourneyMatrixLoaded event,
    Emitter<MetroState> emit,
  ) {
    emit(state.copyWith(journeyMatrix: event.matrix));
  }
}
