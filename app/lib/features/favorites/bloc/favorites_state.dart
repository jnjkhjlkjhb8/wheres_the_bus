import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';

class FavoritesState extends Equatable {
  const FavoritesState({this.items = const []});

  final List<Favorite> items;

  List<Favorite> get pinned => items.where((f) => f.pinned).toList();

  bool contains(String id) => items.any((f) => f.id == id);

  @override
  List<Object?> get props => [items];
}
