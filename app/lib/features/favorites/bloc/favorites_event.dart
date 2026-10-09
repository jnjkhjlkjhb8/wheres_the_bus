import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';

sealed class FavoritesEvent extends Equatable {
  const FavoritesEvent();

  @override
  List<Object?> get props => [];
}

class FavoritesRefreshed extends FavoritesEvent {
  const FavoritesRefreshed();
}

class FavoriteToggled extends FavoritesEvent {
  const FavoriteToggled(this.favorite);

  final Favorite favorite;

  @override
  List<Object?> get props => [favorite];
}

class FavoritePinChanged extends FavoritesEvent {
  const FavoritePinChanged(this.id, {required this.pinned});

  final String id;
  final bool pinned;

  @override
  List<Object?> get props => [id, pinned];
}

class FavoriteRemoved extends FavoritesEvent {
  const FavoriteRemoved(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

class FavoritesReordered extends FavoritesEvent {
  const FavoritesReordered(this.ordered);

  final List<Favorite> ordered;

  @override
  List<Object?> get props => [ordered];
}
