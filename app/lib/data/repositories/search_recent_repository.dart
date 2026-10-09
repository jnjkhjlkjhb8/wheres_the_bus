import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';

class SearchRecentRepository {
  const SearchRecentRepository._();
  static const instance = SearchRecentRepository._();

  static const _key = 'recent_search_results';
  static const _maxItems = 8;

  List<SearchResult> all() {
    if (!HiveStore.settingsReady) return const [];
    final raw = HiveStore.settings.get(_key, defaultValue: <dynamic>[]);
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(SearchResult.fromStorageMap)
        .whereType<SearchResult>()
        .toList(growable: false);
  }

  Future<void> add(SearchResult result) async {
    if (!HiveStore.settingsReady) return;
    final current = all()
        .where((r) => r.type != result.type || r.uid != result.uid)
        .toList();
    final next = [
      result,
      ...current,
    ].take(_maxItems).map((r) => r.toStorageMap()).toList();
    await HiveStore.settings.put(_key, next);
  }

  Future<void> remove(SearchResult result) async {
    if (!HiveStore.settingsReady) return;
    final next = all()
        .where((r) => r.type != result.type || r.uid != result.uid)
        .map((r) => r.toStorageMap())
        .toList();
    await HiveStore.settings.put(_key, next);
  }

  Future<void> restore(SearchResult result, int index) async {
    if (!HiveStore.settingsReady) return;
    final current = all()
        .where((r) => r.type != result.type || r.uid != result.uid)
        .toList();
    current.insert(index.clamp(0, current.length), result);
    final next = current.take(_maxItems).map((r) => r.toStorageMap()).toList();
    await HiveStore.settings.put(_key, next);
  }

  Future<void> clear() async {
    if (!HiveStore.settingsReady) return;
    await HiveStore.settings.delete(_key);
  }
}
