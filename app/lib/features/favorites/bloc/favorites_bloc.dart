import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_state.dart';

class FavoritesBloc extends Bloc<FavoritesEvent, FavoritesState> {
  FavoritesBloc(this._repo, this._ready) : super(const FavoritesState()) {
    on<FavoritesRefreshed>(
      (_, emit) => emit(FavoritesState(items: _repo.all())),
    );
    on<FavoriteToggled>((e, emit) => _repo.toggle(e.favorite));
    on<FavoritePinChanged>(
      (e, emit) => _repo.setPinned(e.id, pinned: e.pinned),
    );
    on<FavoriteRemoved>((e, emit) => _repo.remove(e.id));
    on<FavoritesReordered>((e, emit) => _repo.saveOrder(e.ordered));

    if (_ready.value) {
      _start();
    } else {
      _ready.addListener(_onReady);
    }
  }

  final FavoritesRepository _repo;
  final ValueListenable<bool> _ready;
  StreamSubscription<void>? _sub;

  void _onReady() {
    if (_ready.value) {
      _ready.removeListener(_onReady);
      _start();
    }
  }

  void _start() {
    add(const FavoritesRefreshed());
    // Consume the repository's coalesced change signal: one user action (even
    // an N-item reorder) yields a single refresh instead of one per box event.
    _sub = _repo.changes().listen(
      (_) => add(const FavoritesRefreshed()),
      onError: CrashReporter.record,
    );
  }

  @override
  Future<void> close() async {
    _ready.removeListener(_onReady);
    await _sub?.cancel();
    return super.close();
  }
}
