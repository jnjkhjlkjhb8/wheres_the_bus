import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';

/// In-memory [RemindersStore] mirroring the real box semantics: reminders are
/// scoped per route, and expired entries are filtered on read.
class InMemoryRemindersStore implements RemindersStore {
  final Map<String, Map<String, _Entry>> _byRoute = {};

  @override
  Map<String, String> active(String routeUid) {
    final entries = _byRoute[routeUid];
    if (entries == null) return {};
    final now = DateTime.now();
    return {
      for (final e in entries.entries)
        if (e.value.expiresAt.isAfter(now)) e.key: e.value.id,
    };
  }

  @override
  Future<void> put(
    String routeUid,
    String stopUid,
    String reminderId,
    DateTime expiresAt,
  ) async {
    (_byRoute[routeUid] ??= {})[stopUid] = _Entry(reminderId, expiresAt);
  }

  @override
  Future<void> remove(String routeUid, String stopUid) async {
    final entries = _byRoute[routeUid];
    if (entries == null) return;
    entries.remove(stopUid);
    if (entries.isEmpty) _byRoute.remove(routeUid);
  }
}

class _Entry {
  const _Entry(this.id, this.expiresAt);
  final String id;
  final DateTime expiresAt;
}
