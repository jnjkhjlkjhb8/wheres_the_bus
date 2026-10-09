import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';

import '../../support/helpers/in_memory_settings_store.dart';

AlertRepository _repo(Map<String, Object?> initial) => AlertRepository(
  settings: SettingsRepository(store: InMemorySettingsStore(initial)),
);

void main() {
  test('read messages are hydrated from the repository on construction', () {
    final bloc = AlertBloc(
      repository: _repo({
        'read_alerts': ['已讀通知'],
      }),
    );
    addTearDown(bloc.close);
    expect(bloc.state.readMessages, contains('已讀通知'));
  });

  test('marking an alert read persists it through the repository', () async {
    final repository = _repo(const {});
    final bloc = AlertBloc(repository: repository);
    addTearDown(bloc.close);

    final marked = expectLater(
      bloc.stream,
      emitsThrough(
        isA<AlertState>().having(
          (s) => s.readMessages,
          'readMessages',
          contains('中和線延誤'),
        ),
      ),
    );
    bloc.add(const AlertMarkedRead('中和線延誤'));
    await marked;

    // The persisted set is observable through a fresh read.
    expect(repository.readAlerts(), contains('中和線延誤'));
  });

  test('AlertReceived stores the batch a source reported', () async {
    final bloc = AlertBloc(repository: _repo(const {}));
    addTearDown(bloc.close);

    const alert = AlertViewModel(message: '紅色警示', level: AlertSeverity.red);
    final next = expectLater(
      bloc.stream,
      emits(
        isA<AlertState>().having(
          (s) => s.activeAlerts,
          'activeAlerts',
          contains(alert),
        ),
      ),
    );
    bloc.add(const AlertReceived(AlertSource(AlertSourceKind.tra), [alert]));
    await next;
  });
}
