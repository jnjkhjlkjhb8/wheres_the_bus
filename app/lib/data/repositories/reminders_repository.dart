import 'package:wheres_the_bus/core/storage/hive_store.dart';

class RemindersRepository {
  RemindersRepository({RemindersStore? store})
    : _store = store ?? const _HiveRemindersStore();

  static final RemindersRepository instance = RemindersRepository();

  final RemindersStore _store;

  /// Active (non-expired) reminders for [routeUid]: stopUid -> reminderId.
  Map<String, String> active(String routeUid) => _store.active(routeUid);

  Future<void> put(
    String routeUid,
    String stopUid,
    String reminderId,
    DateTime expiresAt,
  ) => _store.put(routeUid, stopUid, reminderId, expiresAt);

  Future<void> remove({required String routeUid, required String stopUid}) =>
      _store.remove(routeUid: routeUid, stopUid: stopUid);
}

/// Persistence seam for [RemindersRepository]. The real store is Hive-backed;
/// tests inject an in-memory store so no box needs opening.
abstract interface class RemindersStore {
  Map<String, String> active(String routeUid);
  Future<void> put(
    String routeUid,
    String stopUid,
    String reminderId,
    DateTime expiresAt,
  );
  Future<void> remove({required String routeUid, required String stopUid});
}

/// Hive-backed [RemindersStore] delegating to the existing box helpers.
class _HiveRemindersStore implements RemindersStore {
  const _HiveRemindersStore();

  @override
  Map<String, String> active(String routeUid) =>
      HiveStore.activeReminders(routeUid);

  @override
  Future<void> put(
    String routeUid,
    String stopUid,
    String reminderId,
    DateTime expiresAt,
  ) => HiveStore.putReminder(routeUid, stopUid, reminderId, expiresAt);

  @override
  Future<void> remove({required String routeUid, required String stopUid}) =>
      HiveStore.removeReminder(routeUid, stopUid);
}
