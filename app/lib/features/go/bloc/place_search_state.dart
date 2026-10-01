import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

/// Why a place lookup was started, so the listener knows what to do with the
/// resolved place: hand it to the host, or open the save dialog on it.
enum ResolveIntent { pick, save }

enum PlaceSearchErrorKind { location, place }

class PlaceSearchEffect extends Equatable {
  const PlaceSearchEffect({
    required this.seq,
    this.resolved,
    this.intent,
    this.error,
  });

  final int seq;
  final PlannedPlace? resolved;
  final ResolveIntent? intent;
  final PlaceSearchErrorKind? error;

  @override
  List<Object?> get props => [seq, resolved, intent, error];
}

class PlaceSearchState extends Equatable {
  const PlaceSearchState({
    this.query = '',
    this.results = const [],
    this.recents = const [],
    this.saved = const [],
    this.loading = false,
    this.resolvingLocation = false,
    this.pickingId,
    this.effect,
  });

  /// The trimmed query. Empty means the shortcut list is showing.
  final String query;
  final List<PlaceSuggestion> results;
  final List<PlannedPlace> recents;
  final List<PlannedPlace> saved;

  /// True from the keystroke until its autocomplete settles, debounce included.
  final bool loading;
  final bool resolvingLocation;

  /// The placeId with a `details()` fetch in flight, so only that row shows a
  /// busy state instead of the whole list.
  final String? pickingId;

  final PlaceSearchEffect? effect;

  bool get isEmptyQuery => query.isEmpty;

  PlaceSearchState copyWith({
    String? query,
    List<PlaceSuggestion>? results,
    List<PlannedPlace>? recents,
    List<PlannedPlace>? saved,
    bool? loading,
    bool? resolvingLocation,
    String? pickingId,
    bool clearPicking = false,
    PlaceSearchEffect? effect,
  }) {
    return PlaceSearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      recents: recents ?? this.recents,
      saved: saved ?? this.saved,
      loading: loading ?? this.loading,
      resolvingLocation: resolvingLocation ?? this.resolvingLocation,
      pickingId: clearPicking ? null : pickingId ?? this.pickingId,
      effect: effect ?? this.effect,
    );
  }

  @override
  List<Object?> get props => [
    query,
    results,
    recents,
    saved,
    loading,
    resolvingLocation,
    pickingId,
    effect,
  ];
}
