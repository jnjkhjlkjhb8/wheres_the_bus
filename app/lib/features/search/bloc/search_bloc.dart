import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_ranking.dart';
import 'package:wheres_the_bus/features/search/bloc/search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({
    SearchRepository? searchRepository,
    SearchRecentRepository recentRepository = SearchRecentRepository.instance,
    SearchAffinityRepository affinityRepository =
        SearchAffinityRepository.instance,
    FavoritesRepository? favoritesRepository,
    LocationService? locationService,
    DateTime Function()? now,
  }) : _searchRepository = searchRepository ?? SearchRepository.instance,
       _recentRepository = recentRepository,
       _affinityRepository = affinityRepository,
       _favoritesRepository =
           favoritesRepository ?? FavoritesRepository.instance,
       _locationService = locationService ?? LocationService.instance,
       _now = now ?? DateTime.now,
       super(const SearchState()) {
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchQuerySubmitted>(_onQuerySubmitted);
    on<SearchCityToggled>(_onCityToggled);
    on<SearchCleared>(_onCleared);
    on<SearchSuggestionsRequested>(_onSuggestionsRequested);
    on<SearchRecentRemoved>(_onRecentRemoved);
    on<SearchRecentRestored>(_onRecentRestored);
    on<SearchRecentsCleared>(_onRecentsCleared);
    on<SearchResultSelected>(_onResultSelected);
    add(const SearchSuggestionsRequested());
  }

  static const _debounceDelay = Duration(milliseconds: 180);

  final SearchRepository _searchRepository;
  final SearchRecentRepository _recentRepository;
  final SearchAffinityRepository _affinityRepository;
  final FavoritesRepository _favoritesRepository;
  final LocationService _locationService;
  final DateTime Function() _now;
  Timer? _debounce;
  int _requestId = 0;

  /// Last known fix, read once when the screen opens rather than per
  /// keystroke. Null until then, and null forever without permission —
  /// ranking simply drops the distance signal.
  Position? _fix;

  void _onQueryChanged(
    SearchQueryChanged event,
    Emitter<SearchState> emit,
  ) {
    final q = event.query.trim();
    final requestId = ++_requestId;
    emit(state.copyWith(query: q, clearError: true));

    _debounce?.cancel();
    if (q.isEmpty) {
      // An empty query shows recents, where the chip row isn't rendered — a
      // filter kept here would be state the user can't see or undo.
      emit(
        state.copyWith(
          results: [],
          loading: false,
          clearCity: true,
          cityOptions: const [],
        ),
      );
      return;
    }

    emit(state.copyWith(loading: true));
    final city = state.city;
    _debounce = Timer(_debounceDelay, () {
      if (!isClosed) add(SearchQuerySubmitted(q, requestId, city: city));
    });
  }

  /// Re-queries under the new filter instead of narrowing the results in
  /// place: the response is capped, so the rows already on screen are only
  /// that city's share of the top of the list, not its rows.
  void _onCityToggled(SearchCityToggled event, Emitter<SearchState> emit) {
    if (state.query.isEmpty) return;
    final city = state.city == event.city ? null : event.city;
    final requestId = ++_requestId;
    _debounce?.cancel();
    emit(
      state.copyWith(
        city: city,
        clearCity: city == null,
        loading: true,
        clearError: true,
      ),
    );
    // No debounce: a tap is a decision, not a keystroke on the way to one.
    add(SearchQuerySubmitted(state.query, requestId, city: city));
  }

  Future<void> _onQuerySubmitted(
    SearchQuerySubmitted event,
    Emitter<SearchState> emit,
  ) async {
    if (event.requestId != _requestId || event.query != state.query) return;
    try {
      final results = await _searchRepository.search(
        event.query,
        city: event.city,
      );
      if (event.requestId == _requestId && !isClosed) {
        emit(
          state.copyWith(
            results: _rank(results, event.query),
            loading: false,
            clearError: true,
            cityOptions: event.city == null ? _cityOptions(results) : null,
          ),
        );
      }
    } on Object catch (e) {
      if (event.requestId == _requestId && !isClosed) {
        emit(
          state.copyWith(
            results: const [],
            loading: false,
            error: AppError.from(e),
          ),
        );
      }
    }
  }

  static List<String> _cityOptions(List<SearchResult> results) {
    final counts = <String, int>{};
    for (final r in results) {
      final city = r.city;
      if (city == null || city.isEmpty) continue;
      counts[city] = (counts[city] ?? 0) + 1;
    }
    final codes = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : cityOrder(a).compareTo(cityOrder(b));
      });
    return codes;
  }

  List<SearchResult> _rank(List<SearchResult> results, String query) =>
      rankSearchResults(
        results,
        query: query,
        favorites: _favoritesRepository.isReady
            ? _favoritesRepository.all()
            : const [],
        affinity: _affinityRepository.all(),
        now: _now(),
        fix: _fix,
      );

  void _onCleared(SearchCleared _, Emitter<SearchState> emit) {
    _debounce?.cancel();
    _requestId++;
    emit(
      SearchState(recentResults: state.recentResults),
    );
  }

  Future<void> _onSuggestionsRequested(
    SearchSuggestionsRequested _,
    Emitter<SearchState> emit,
  ) async {
    emit(state.copyWith(recentResults: _recentRepository.all()));
    final fix = await _locationService.lastKnownPosition();
    if (fix != null && !isClosed) _fix = fix;
  }

  Future<void> _onRecentRemoved(
    SearchRecentRemoved event,
    Emitter<SearchState> emit,
  ) async {
    await _recentRepository.remove(event.result);
    emit(state.copyWith(recentResults: _recentRepository.all()));
  }

  Future<void> _onRecentRestored(
    SearchRecentRestored event,
    Emitter<SearchState> emit,
  ) async {
    await _recentRepository.restore(event.result, event.index);
    emit(state.copyWith(recentResults: _recentRepository.all()));
  }

  Future<void> _onRecentsCleared(
    SearchRecentsCleared _,
    Emitter<SearchState> emit,
  ) async {
    await _recentRepository.clear();
    await _affinityRepository.clear();
    emit(state.copyWith(recentResults: const []));
  }

  Future<void> _onResultSelected(
    SearchResultSelected event,
    Emitter<SearchState> emit,
  ) async {
    await _recentRepository.add(event.result);
    await _affinityRepository.record(
      event.result,
      query: state.query,
      now: _now(),
    );
    emit(state.copyWith(recentResults: _recentRepository.all()));
  }

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
