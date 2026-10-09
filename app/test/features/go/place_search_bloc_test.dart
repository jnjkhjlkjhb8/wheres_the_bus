import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/repositories/place_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';
import 'package:wheres_the_bus/data/repositories/saved_place_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_event.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

void main() {
  test('start hydrates recents and saved places', () async {
    final bloc = _bloc(
      recents: _FakeRecents([_place('Taipei 101')]),
      saved: _FakeSaved([_place('Home')]),
    );

    final settled = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlaceSearchState>()
            .having((s) => s.recents.single.name, 'recent', 'Taipei 101')
            .having((s) => s.saved.single.name, 'saved', 'Home'),
      ),
    );
    bloc.add(const PlaceSearchStarted());
    await settled;
  });

  test('rapid keystrokes coalesce into one autocomplete call', () async {
    final places = _FakePlaces();
    _bloc(places: places, debounce: _tick)
      ..add(const PlaceQueryChanged('t'))
      ..add(const PlaceQueryChanged('ta'))
      ..add(const PlaceQueryChanged('tai'));

    await _settle();
    expect(places.queries, ['tai']);
  });

  test('a late response for a superseded query is dropped', () async {
    final places = _FakePlaces();
    final bloc = _bloc(places: places)..add(const PlaceQueryChanged('slow'));
    await _settle();
    bloc.add(const PlaceQueryChanged('fast'));
    await _settle();
    places.complete('fast', [_suggestion('fast-1')]);
    await _settle();

    // 'slow' answers only now, after the rider has typed on.
    places.complete('slow', [_suggestion('slow-1')]);
    await _settle();

    expect(bloc.state.query, 'fast');
    expect(bloc.state.results.single.placeId, 'fast-1');
    expect(bloc.state.loading, isFalse);
  });

  test('picking records a recent, saving does not', () async {
    final recents = _FakeRecents();
    final places = _FakePlaces()..detailsById['p1'] = _place('Zhongshan');
    final bloc = _bloc(places: places, recents: recents)
      ..add(const PlaceResolveRequested('p1', ResolveIntent.pick));
    await _settle();
    expect(recents.items.single.name, 'Zhongshan');
    expect(bloc.state.effect?.intent, ResolveIntent.pick);
    expect(bloc.state.effect?.resolved?.name, 'Zhongshan');

    bloc.add(const PlaceResolveRequested('p1', ResolveIntent.save));
    await _settle();
    expect(recents.items, hasLength(1));
    expect(bloc.state.effect?.intent, ResolveIntent.save);
  });

  test('a resolve in flight blocks a second one', () async {
    final places = _FakePlaces()..holdDetails = true;
    final bloc = _bloc(places: places)
      ..add(const PlaceResolveRequested('p1', ResolveIntent.pick));
    await _settle();
    bloc.add(const PlaceResolveRequested('p2', ResolveIntent.pick));
    await _settle();

    expect(bloc.state.pickingId, 'p1');
    expect(places.detailIds, ['p1']);
  });

  test('two failed resolves both reach the view', () async {
    final bloc = _bloc(places: _FakePlaces())
      ..add(const PlaceResolveRequested('missing', ResolveIntent.pick));
    await _settle();
    final first = bloc.state.effect;
    bloc.add(const PlaceResolveRequested('missing', ResolveIntent.pick));
    await _settle();

    expect(first?.error, PlaceSearchErrorKind.place);
    expect(bloc.state.effect?.error, PlaceSearchErrorKind.place);
    expect(bloc.state.effect, isNot(first));
  });

  test('removing then restoring round-trips both lists', () async {
    final home = _place('Home');
    final recent = _place('Ximen');
    final bloc = _bloc(
      recents: _FakeRecents([recent]),
      saved: _FakeSaved([home]),
    )..add(const PlaceSearchStarted());
    await _settle();

    bloc
      ..add(SavedRemoved(home))
      ..add(RecentRemoved(recent));
    await _settle();
    expect(bloc.state.saved, isEmpty);
    expect(bloc.state.recents, isEmpty);

    bloc
      ..add(SavedRestored(home))
      ..add(RecentRestored(recent));
    await _settle();
    expect(bloc.state.saved.single.name, 'Home');
    expect(bloc.state.recents.single.name, 'Ximen');
  });
}

const _tick = Duration(milliseconds: 5);

PlaceSearchBloc _bloc({
  PlacesRepository? places,
  PlaceRecentRepository? recents,
  SavedPlaceRepository? saved,
  Duration debounce = Duration.zero,
}) {
  final bloc = PlaceSearchBloc(
    places: places ?? _FakePlaces(),
    recents: recents ?? _FakeRecents(),
    saved: saved ?? _FakeSaved(),
    debounce: debounce,
  );
  addTearDown(bloc.close);
  return bloc;
}

/// Lets every pending microtask and the short debounce run out.
Future<void> _settle() => Future<void>.delayed(_tick * 4);

PlannedPlace _place(String name) =>
    PlannedPlace(name: name, latLng: LatLng(25.0 + name.length / 1000, 121.5));

PlaceSuggestion _suggestion(String id) =>
    PlaceSuggestion(placeId: id, primaryText: id, secondaryText: '');

class _FakePlaces implements PlacesRepository {
  final queries = <String>[];
  final detailIds = <String>[];
  final detailsById = <String, PlannedPlace>{};

  /// When true, `details()` never completes — for the in-flight guard.
  bool holdDetails = false;

  final _pending = <String, Completer<List<PlaceSuggestion>>>{};

  /// Answers a query that is still waiting. Untouched queries stay pending.
  void complete(String query, List<PlaceSuggestion> results) =>
      _pending.remove(query)?.complete(results);

  @override
  Future<List<PlaceSuggestion>> autocomplete(String query, {LatLng? bias}) {
    queries.add(query);
    return (_pending[query] = Completer<List<PlaceSuggestion>>()).future;
  }

  @override
  Future<PlannedPlace> details(String placeId) {
    detailIds.add(placeId);
    if (holdDetails) return Completer<PlannedPlace>().future;
    final place = detailsById[placeId];
    if (place == null) return Future.error(StateError('no such place'));
    return Future.value(place);
  }
}

class _FakeRecents implements PlaceRecentRepository {
  _FakeRecents([List<PlannedPlace>? initial]) : items = [...?initial];

  final List<PlannedPlace> items;

  @override
  List<PlannedPlace> all() => List.unmodifiable(items);

  @override
  Future<void> add(PlannedPlace place) async {
    items
      ..removeWhere((p) => p.name == place.name)
      ..insert(0, place);
  }

  @override
  Future<void> remove(PlannedPlace place) async =>
      items.removeWhere((p) => p.name == place.name);
}

class _FakeSaved implements SavedPlaceRepository {
  _FakeSaved([List<PlannedPlace>? initial]) : items = [...?initial];

  final List<PlannedPlace> items;

  @override
  List<PlannedPlace> all() => List.unmodifiable(items);

  @override
  Future<void> add(PlannedPlace place) async {
    items
      ..removeWhere((p) => p.latLng == place.latLng)
      ..add(place);
  }

  @override
  Future<void> remove(PlannedPlace place) async =>
      items.removeWhere((p) => p.latLng == place.latLng);

  @override
  bool contains(PlannedPlace place) =>
      items.any((p) => p.latLng == place.latLng);
}
