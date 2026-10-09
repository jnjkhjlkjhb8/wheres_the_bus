import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

/// In-memory [SettingsStore] so repository/bloc tests never open a Hive box.
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([Map<String, Object?>? initial])
    : _values = {...?initial};

  final Map<String, Object?> _values;

  @override
  bool get ready => true;

  @override
  Object? get(String key, {Object? defaultValue}) =>
      _values.containsKey(key) ? _values[key] : defaultValue;

  @override
  Future<void> put(String key, Object? value) async {
    _values[key] = value;
  }
}
