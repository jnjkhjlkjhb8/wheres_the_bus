import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';

import '../../support/helpers/in_memory_settings_store.dart';

AlertRepository _repo([Map<String, Object?> initial = const {}]) =>
    AlertRepository(
      settings: SettingsRepository(store: InMemorySettingsStore(initial)),
    );

AlertViewModel _notice(
  String message, {
  required AlertSourceKind kind,
  AlertSeverity level = AlertSeverity.yellow,
}) => AlertViewModel(
  message: message,
  level: level,
  source: AlertSource(kind),
);

const _disruption = AlertSourceId(AlertSourceKind.metro);

void main() {
  group('notice kind and tone', () {
    test('a disruption takes its tone from severity', () {
      expect(
        _notice(
          '停駛',
          kind: AlertSourceKind.metro,
          level: AlertSeverity.red,
        ).tone,
        NoticeTone.critical,
      );
      expect(
        _notice('延誤', kind: AlertSourceKind.tra).tone,
        NoticeTone.caution,
      );
    });

    test(
      'an announcement never reaches critical, whatever the feed puts on it',
      () {
        final announcement = _notice(
          '新功能上線',
          kind: AlertSourceKind.appNotice,
          level: AlertSeverity.red,
        );
        expect(announcement.tone, NoticeTone.info);
        expect(announcement.kind, NoticeKind.announcement);
      },
    );
  });

  group('inbox grouping', () {
    AlertState stateWith(List<AlertViewModel> notices) =>
        AlertState(alertsBySource: {_disruption: notices});

    test('進行中 holds disruptions, 訊息 holds announcements', () {
      final state = stateWith([
        _notice('停駛', kind: AlertSourceKind.metro, level: AlertSeverity.red),
        _notice('路線異動', kind: AlertSourceKind.busAlert),
        _notice('新功能上線', kind: AlertSourceKind.appNotice),
      ]);

      expect(state.ongoingNotices.map((n) => n.message), ['停駛', '路線異動']);
      expect(state.messageNotices.map((n) => n.message), ['新功能上線']);
    });

    test('an announcement cannot reach the interrupt layer', () {
      final state = stateWith([
        _notice(
          '重大公告',
          kind: AlertSourceKind.appNotice,
          level: AlertSeverity.red,
        ),
      ]);
      expect(state.redAlerts, isEmpty);
    });
  });

  test('announcements arrive through the bloc like any other source', () async {
    final bloc = AlertBloc(
      repository: _repo(),
      alertSourcesConfig: Stream<String>.empty,
      scopeSource: Stream<Set<String>>.empty,
      announcements: () => Stream.value([
        _notice('新功能上線', kind: AlertSourceKind.appNotice),
      ]),
    );
    addTearDown(bloc.close);

    final landed = expectLater(
      bloc.stream,
      emitsThrough(
        isA<AlertState>().having(
          (s) => s.messageNotices.map((n) => n.message),
          'messageNotices',
          contains('新功能上線'),
        ),
      ),
    );
    bloc.add(const AlertStarted());
    await landed;
  });
}
