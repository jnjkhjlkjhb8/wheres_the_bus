import 'package:wheres_the_bus/core/powersync/local_db.dart';

class FakeLocalDb implements LocalDb {
  FakeLocalDb(this._rowsByKey) : _error = null;

  /// A [LocalDb] whose every [getAll] call throws [error], e.g. to simulate
  /// `no such table` before PowerSync has synced, or a DB that never
  /// initialized. `_rowsByKey` is unused in this mode.
  FakeLocalDb.throwing(Object error) : _error = error, _rowsByKey = const {};

  /// Maps the first query parameter to the rows that query should return.
  final Map<Object?, List<Map<String, dynamic>>> _rowsByKey;

  /// When set, every [getAll] call throws this instead of returning rows.
  final Object? _error;

  /// Queries recorded in call order, for assertions.
  final List<({String sql, List<Object?> parameters})> calls = [];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    calls.add((sql: sql, parameters: parameters));
    final error = _error;
    if (error != null) {
      // The fake reproduces the supplied failure object.
      // ignore: only_throw_errors
      throw error;
    }
    final key = parameters.isEmpty ? null : parameters.first;
    return _rowsByKey[key] ?? const [];
  }
}
