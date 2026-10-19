import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/repositories/place_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';
import 'package:wheres_the_bus/data/repositories/saved_place_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_event.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

/// Owns the place-search data: the autocomplete round trip, the recents and
/// saved-place lists, and the coordinate lookup a suggestion needs before it
/// can be used. The view keeps the text field, the dialogs, and the snackbars.
class PlaceSearchBloc extends Bloc<PlaceSearchEvent, PlaceSearchState> {
  PlaceSearchBloc({
    PlacesRepository? places,
    PlaceRecentRepository? recents,
    SavedPlaceRepository? saved,
    Duration debounce = const Duration(milliseconds: 300),
  }) : _places = places ?? PlacesRepository.instance,
       _recents = recents ?? PlaceRecentRepository.instance,
       _saved = saved ?? SavedPlaceRepository.instance,
       _debounce = debounce,
       super(const PlaceSearchState()) {
    on<PlaceSearchStarted>(_onStarted);
    on<PlaceQueryChanged>(_onQueryChanged, transformer: restartable());
    on<PlaceResolveRequested>(_onResolveRequested);
    on<LocationResolving>(_onLocationResolving);
    on<PlaceSaved>(_onPlaceSaved);
    on<RecentRemoved>(_onRecentRemoved);
    on<RecentRestored>(_onRecentRestored);
    on<SavedRemoved>(_onSavedRemoved);
    on<SavedRestored>(_onSavedRestored);
  }

  final PlacesRepository _places;
  final PlaceRecentRepository _recents;
  final SavedPlaceRepository _saved;
  final Duration _debounce;

  int _effectSeq = 0;

  PlaceSearchEffect _effect({
    PlannedPlace? resolved,
    ResolveIntent? intent,
    PlaceSearchErrorKind? error,
  }) => PlaceSearchEffect(
    seq: ++_effectSeq,
    resolved: resolved,
    intent: intent,
    error: error,
  );

  void _onStarted(PlaceSearchStarted event, Emitter<PlaceSearchState> emit) {
    emit(state.copyWith(recents: _recents.all(), saved: _saved.all()));
  }

  Future<void> _onQueryChanged(
    PlaceQueryChanged event,
    Emitter<PlaceSearchState> emit,
  ) async {
    final query = event.query.trim();
    if (query.isEmpty) {
      emit(state.copyWith(query: '', results: const [], loading: false));
      return;
    }
    emit(state.copyWith(query: query, loading: true));

    await Future<void>.delayed(_debounce);
    if (_obsoleteQuery(query, emit)) return;

    final results = await _autocomplete(query, event.bias);
    if (_obsoleteQuery(query, emit)) return;
    emit(state.copyWith(results: results, loading: false));
  }

  bool _obsoleteQuery(String query, Emitter<PlaceSearchState> emit) =>
      emit.isDone || state.query != query;

  Future<List<PlaceSuggestion>> _autocomplete(
    String query,
    LatLng? bias,
  ) async {
    try {
      return await _places.autocomplete(query, bias: bias);
    } on Object {
      // A keystroke retries, so an empty match list avoids a noisy alert.
      return const [];
    }
  }

  Future<void> _onResolveRequested(
    PlaceResolveRequested event,
    Emitter<PlaceSearchState> emit,
  ) async {
    if (state.pickingId != null) return;
    emit(state.copyWith(pickingId: event.placeId));
    try {
      final place = await _places.details(event.placeId);
      if (event.intent == ResolveIntent.pick) await _recents.add(place);
      _emitResolvedPlace(place, event.intent, emit);
    } on Object {
      _emitResolveFailure(emit);
    }
  }

  void _emitResolvedPlace(
    PlannedPlace place,
    ResolveIntent intent,
    Emitter<PlaceSearchState> emit,
  ) {
    if (emit.isDone) return;
    emit(
      state.copyWith(
        clearPicking: true,
        recents: _recents.all(),
        effect: _effect(resolved: place, intent: intent),
      ),
    );
  }

  void _emitResolveFailure(Emitter<PlaceSearchState> emit) {
    if (emit.isDone) return;
    emit(
      state.copyWith(
        clearPicking: true,
        effect: _effect(error: PlaceSearchErrorKind.place),
      ),
    );
  }

  void _onLocationResolving(
    LocationResolving event,
    Emitter<PlaceSearchState> emit,
  ) {
    emit(
      state.copyWith(
        resolvingLocation: event.active,
        effect: event.failed
            ? _effect(error: PlaceSearchErrorKind.location)
            : null,
      ),
    );
  }

  Future<void> _onPlaceSaved(
    PlaceSaved event,
    Emitter<PlaceSearchState> emit,
  ) async {
    await _saved.add(
      event.place.copyWith(name: event.name, iconKey: event.iconKey),
    );
    if (emit.isDone) return;
    emit(state.copyWith(saved: _saved.all()));
  }

  Future<void> _onRecentRemoved(
    RecentRemoved event,
    Emitter<PlaceSearchState> emit,
  ) => _mutateRecents(emit, () => _recents.remove(event.place));

  Future<void> _onRecentRestored(
    RecentRestored event,
    Emitter<PlaceSearchState> emit,
  ) => _mutateRecents(emit, () => _recents.add(event.place));

  Future<void> _onSavedRemoved(
    SavedRemoved event,
    Emitter<PlaceSearchState> emit,
  ) => _mutateSaved(emit, () => _saved.remove(event.place));

  Future<void> _onSavedRestored(
    SavedRestored event,
    Emitter<PlaceSearchState> emit,
  ) => _mutateSaved(emit, () => _saved.add(event.place));

  Future<void> _mutateRecents(
    Emitter<PlaceSearchState> emit,
    Future<void> Function() write,
  ) async {
    await write();
    if (emit.isDone) return;
    emit(state.copyWith(recents: _recents.all()));
  }

  Future<void> _mutateSaved(
    Emitter<PlaceSearchState> emit,
    Future<void> Function() write,
  ) async {
    await write();
    if (emit.isDone) return;
    emit(state.copyWith(saved: _saved.all()));
  }
}
