import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';

void main() {
  test('before initialization favorites are empty and unavailable', () {
    final repo = FavoritesRepository.instance;
    expect(repo.isReady, isFalse);
    expect(repo.isFavorite('missing'), isFalse);
    expect(repo.all(), isEmpty);
  });
}
