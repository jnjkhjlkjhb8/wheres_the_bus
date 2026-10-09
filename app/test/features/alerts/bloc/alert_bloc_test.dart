import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';

import '../../../support/helpers/in_memory_settings_store.dart';

void main() {
  test('AlertBloc does not subscribe on construction', () async {
    final bloc = AlertBloc();
    addTearDown(bloc.close);

    expect(bloc.hasActiveSubscriptions, isFalse);
  });

  const traSource = AlertSourceId(AlertSourceKind.tra);
  const busSource = AlertSourceId(AlertSourceKind.busAlert, 'Taipei');

  test("AlertReceived adds a source's alerts to active alerts", () async {
    final bloc = AlertBloc();
    addTearDown(bloc.close);

    const alert = AlertViewModel(message: '中和線延誤', level: AlertSeverity.red);

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

    bloc.add(const AlertReceived(traSource, [alert]));
    await next;
  });

  // Each message is that channel's whole current set, so an alert TDX has
  // stopped publishing has been resolved and must leave the list. Before the
  // snapshot semantics, a resolved disruption stayed on screen forever.
  test('a later batch replaces its own source and leaves others', () async {
    final bloc = AlertBloc();
    addTearDown(bloc.close);

    bloc
      ..add(
        const AlertReceived(traSource, [
          AlertViewModel(message: '台鐵誤點', level: AlertSeverity.yellow),
        ]),
      )
      ..add(
        const AlertReceived(busSource, [
          AlertViewModel(message: '公車改道', level: AlertSeverity.yellow),
        ]),
      );
    await pumpEventQueue();
    expect(bloc.state.activeAlerts, hasLength(2));

    bloc.add(const AlertReceived(traSource, []));
    await pumpEventQueue();
    expect(bloc.state.activeAlerts.map((a) => a.message), ['公車改道']);
  });

  group('收藏 scope filtering', () {
    const scoped = AlertViewModel(
      message: '123 次停駛',
      level: AlertSeverity.red,
      routeType: 'tra',
      routeKeys: ['123'],
    );
    const systemWide = AlertViewModel(
      message: '台鐵今日全線停駛',
      level: AlertSeverity.red,
      routeType: 'tra',
    );

    test('a route-scoped alert outside 訂閱範圍 is not shown', () async {
      final bloc = AlertBloc();
      addTearDown(bloc.close);

      bloc.add(const AlertReceived(traSource, [scoped, systemWide]));
      await pumpEventQueue();

      // Nothing is 收藏ed yet: only the system-wide disruption shows, so a
      // fresh install still learns that alerts exist.
      expect(bloc.state.visibleAlerts, [systemWide]);

      bloc.add(const AlertScopeChanged({'tra:123'}));
      await pumpEventQueue();
      expect(bloc.state.visibleAlerts, containsAll([scoped, systemWide]));
    });

    test('changing 收藏 re-filters without refetching', () async {
      final bloc = AlertBloc();
      addTearDown(bloc.close);

      bloc
        ..add(const AlertScopeChanged({'tra:123'}))
        ..add(const AlertReceived(traSource, [scoped]));
      await pumpEventQueue();
      expect(bloc.state.visibleAlerts, [scoped]);

      // Un-收藏ing the train hides its alert from data already in hand.
      bloc.add(const AlertScopeChanged({}));
      await pumpEventQueue();
      expect(bloc.state.visibleAlerts, isEmpty);
      expect(bloc.state.activeAlerts, [scoped]);
    });

    test('a resolved (green) alert is never shown', () async {
      final bloc = AlertBloc();
      addTearDown(bloc.close);

      bloc.add(
        const AlertReceived(traSource, [
          AlertViewModel(message: '已恢復', level: AlertSeverity.green),
        ]),
      );
      await pumpEventQueue();
      expect(bloc.state.visibleAlerts, isEmpty);
    });
  });

  // These two handlers are what the passthrough seam's onFailure/onRecovered
  // callbacks add when the four alert streams drop and recover. The seam's
  // callback pass-through itself is covered in test/data/live/arrival_feed_test.
  test(
    'AlertStreamFailed sets the error, AlertStreamRecovered clears it',
    () async {
      final bloc = AlertBloc();
      addTearDown(bloc.close);

      final sawError = expectLater(
        bloc.stream,
        emits(
          isA<AlertState>().having(
            (s) => s.error,
            'error',
            isA<OfflineError>(),
          ),
        ),
      );
      bloc.add(const AlertStreamFailed(OfflineError()));
      await sawError;

      final cleared = expectLater(
        bloc.stream,
        emits(isA<AlertState>().having((s) => s.error, 'error', isNull)),
      );
      bloc.add(const AlertStreamRecovered());
      await cleared;
    },
  );

  group('source-scoped health (F32)', () {
    const metroA = AlertSourceId(AlertSourceKind.metro, 'TRTC');
    const metroB = AlertSourceId(AlertSourceKind.metro, 'KRTC');

    test(
      'two failed sources with one recovery keeps the global error set',
      () async {
        final bloc = AlertBloc();
        addTearDown(bloc.close);

        bloc
          ..add(const AlertStreamFailed(OfflineError(), source: metroA))
          ..add(const AlertStreamFailed(OfflineError(), source: metroB));
        await pumpEventQueue();
        expect(bloc.state.error, isA<OfflineError>());
        expect(bloc.state.sourceHealth.keys, containsAll([metroA, metroB]));

        bloc.add(const AlertStreamRecovered(source: metroA));
        await pumpEventQueue();

        // The recovered source cleared its own failure only.
        expect(bloc.state.sourceHealth, isNot(contains(metroA)));
        expect(bloc.state.sourceHealth, contains(metroB));
        // The other source is still down, so the global error must not clear.
        expect(bloc.state.error, isA<OfflineError>());
      },
    );

    test('recovering an untracked source is a no-op', () async {
      final bloc = AlertBloc();
      addTearDown(bloc.close);

      bloc.add(const AlertStreamRecovered(source: metroA));
      await pumpEventQueue();
      expect(bloc.state.sourceHealth, isEmpty);
      expect(bloc.state.error, isNull);
    });
  });

  group('dynamic alert_sources config (F33)', () {
    late _RecordingAlertRepository repository;
    late StreamController<String> config;
    late AlertBloc bloc;

    setUp(() {
      repository = _RecordingAlertRepository();
      config = StreamController<String>();
      bloc = AlertBloc(
        repository: repository,
        alertSourcesConfig: () => config.stream,
        scopeSource: () => Stream.value(const <String>{}),
      );
    });

    tearDown(() async {
      await bloc.close();
      await config.close();
    });

    test('startup subscribes the static and initial dynamic sources', () async {
      bloc.add(const AlertStarted());
      await pumpEventQueue();
      config.add('metro:TRTC,bus:Taipei');
      await pumpEventQueue();

      expect(
        repository.subscribed,
        containsAll(['tra', 'thsr', 'metro:TRTC', 'busAlert:Taipei']),
      );
    });

    test('an identical config revision causes no resubscribe', () async {
      bloc.add(const AlertStarted());
      await pumpEventQueue();
      config.add('metro:TRTC,bus:Taipei');
      await pumpEventQueue();
      final before = List<String>.from(repository.subscribed);

      config.add('metro:TRTC,bus:Taipei');
      await pumpEventQueue();

      expect(repository.subscribed, before);
    });

    test(
      'a config revision replaces only the affected subscriptions, '
      'kept sources are never touched',
      () async {
        bloc.add(const AlertStarted());
        await pumpEventQueue();
        config.add('metro:TRTC,bus:Taipei');
        await pumpEventQueue();

        config.add('metro:TRTC,bus:Taichung');
        await pumpEventQueue();

        expect(repository.cancelled, containsAll(['busAlert:Taipei']));
        expect(repository.subscribed, containsAll(['busAlert:Taichung']));
        // The kept metro subscription must never be cancelled.
        expect(repository.cancelled, isNot(contains('metro:TRTC')));
        expect(
          repository.subscribed.where((s) => s == 'metro:TRTC').length,
          1,
        );
      },
    );

    test('close() awaits every subscription cancellation', () async {
      bloc.add(const AlertStarted());
      await pumpEventQueue();
      config.add('metro:TRTC,bus:Taipei');
      await pumpEventQueue();

      await bloc.close();

      expect(
        repository.cancelled,
        containsAll(['tra', 'thsr', 'metro:TRTC', 'busAlert:Taipei']),
      );
    });
  });
}

/// Records subscribe/cancel calls instead of hitting gRPC, so config-revision
/// diffing (F33) can be asserted without a network dependency.
class _RecordingAlertRepository extends AlertRepository {
  _RecordingAlertRepository()
    : super(settings: SettingsRepository(store: InMemorySettingsStore()));

  final List<String> subscribed = [];
  final List<String> cancelled = [];

  Stream<List<AlertViewModel>> _stream(String key) {
    subscribed.add(key);
    final controller = StreamController<List<AlertViewModel>>(
      onCancel: () => cancelled.add(key),
    );
    return controller.stream;
  }

  @override
  Stream<List<AlertViewModel>> traAlert() => _stream('tra');

  @override
  Stream<List<AlertViewModel>> thsrAlert() => _stream('thsr');

  @override
  Stream<List<AlertViewModel>> metroAlert(String system) =>
      _stream('metro:$system');

  @override
  Stream<List<AlertViewModel>> busAlert(String city) =>
      _stream('busAlert:$city');
}
