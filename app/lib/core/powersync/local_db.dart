// Shared read interface for PowerSync and test fakes.
// ignore: one_member_abstracts
abstract interface class LocalDb {
  /// Runs a read-only query and returns each row as a column-keyed map.
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters,
  ]);
}
