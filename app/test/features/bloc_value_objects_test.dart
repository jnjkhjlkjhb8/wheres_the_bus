import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_state.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';

const _session = MrtTrackSession(
  trackId: 't',
  tripId: 'trip',
  carId: 'c',
  pathStationIds: ['a', 'b'],
  pathStationNames: ['A', 'B'],
  targetIndex: 1,
  currentIndex: 0,
  remainingStops: 1,
  nextStationId: 'b',
  nextStationName: 'B',
  progress: 0.5,
  status: MrtTrackStatus.tracking,
  leadStops: 1,
  system: 'TRTC',
);

const _arrival = MetroArrival(line: 'R', destination: 'X', estimateSeconds: 60);

void main() {
  group('rail events', () {
    test('base and simple events', () {
      expect(const RailSystemChanged(RailSystem.thsr).props, [
        RailSystem.thsr,
      ]);
      expect(
        const RailSystemChanged(RailSystem.tra) ==
            const RailSystemChanged(RailSystem.thsr),
        isFalse,
      );
      expect(const RailStationSelection(name: 'n', id: 'i').props, ['n', 'i']);
      expect(const RailStationSelection(name: 'n').id, isNull);
      expect(const RailTrainStopsRequested(trainNo: '1', date: 'd').props, [
        '1',
        'd',
      ]);
      expect(const RailDelaysUpdated({'1': 2}).props, [
        {'1': 2},
      ]);
    });

    test('timetable request props and default direction', () {
      const o = RailStationSelection(name: 'o');
      const d = RailStationSelection(name: 'd');
      const e = RailTimetableRequested(
        system: RailSystem.tra,
        origin: o,
        destination: d,
        date: '2026-01-01',
        cutoffMinutes: 5,
      );
      expect(e.isDeparture, isTrue);
      expect(e.props, [RailSystem.tra, o, d, '2026-01-01', 5, true]);
    });
  });

  group('rail states', () {
    test('props and copyWith', () {
      expect(const RailInitial().props, isEmpty);
      const loading = RailTimetableLoading(
        system: RailSystem.tra,
        originName: 'o',
        destName: 'd',
        date: 'x',
      );
      expect(loading.props, [RailSystem.tra, 'o', 'd', 'x']);

      const quote = RailFareQuote.thsr(
        fares: [ThsrFare(fareClass: 1, price: 1490)],
      );
      const base = RailTimetableLoaded(
        system: RailSystem.tra,
        originName: 'o',
        destName: 'd',
        date: 'x',
      );
      expect(base.fareQuote, isNull);
      expect(base.delays, isEmpty);
      final changed = base.copyWith(
        system: RailSystem.thsr,
        originName: 'o2',
        destName: 'd2',
        date: 'y',
        delays: const {'1': 3},
        fareQuote: quote,
      );
      expect(changed.system, RailSystem.thsr);
      expect(changed.originName, 'o2');
      expect(changed.destName, 'd2');
      expect(changed.date, 'y');
      expect(changed.delays, {'1': 3});
      expect(changed.fareQuote, quote);
      expect(changed.props, [
        RailSystem.thsr,
        'o2',
        'd2',
        'y',
        <Object>[],
        <Object>[],
        {'1': 3},
        quote,
      ]);
      expect(base.copyWith(), base);
      expect(changed.copyWith().fareQuote, quote);

      const stops = RailTrainStopsLoaded(
        system: RailSystem.tra,
        trainNo: '1',
        trainType: 't',
      );
      expect(stops.props, [RailSystem.tra, '1', 't', <Object>[], <Object>[]]);
      expect(const RailError(OfflineError()).props, [const OfflineError()]);
    });

    test('station board states', () {
      const loading = RailStationBoardLoading(
        direction: RailBoardDirection.reverse,
      );
      expect(loading.props, [RailBoardDirection.reverse]);
      final at = DateTime(2026);
      final loaded = RailStationBoardLoaded(
        direction: RailBoardDirection.forward,
        departures: const [],
        delaysUpdatedAt: at,
      );
      expect(loaded.delays, isEmpty);
      expect(loaded.props, [
        RailBoardDirection.forward,
        <Object>[],
        <String, int>{},
        at,
      ]);
      final copy = loaded.copyWith(delays: const {'1': 1});
      expect(copy.direction, RailBoardDirection.forward);
      expect(copy.delaysUpdatedAt, at);
      expect(copy.delays, {'1': 1});
      final later = DateTime(2027);
      expect(loaded.copyWith(delaysUpdatedAt: later).delaysUpdatedAt, later);
      expect(loaded.copyWith().delays, isEmpty);
      const failure = RailStationBoardFailure(
        direction: RailBoardDirection.reverse,
        error: UnknownError(),
      );
      expect(failure.props, [RailBoardDirection.reverse, const UnknownError()]);
    });
  });

  group('metro events and state', () {
    test('mrt track events', () {
      expect(const MrtAlightPickStarted(_arrival).props, [_arrival]);
      expect(const MrtAlightTargetPicked('s').props, ['s']);
      expect(const MrtAlightLeadChanged(3).props, [3]);
      expect(const MrtTrackUpdated(_session).props, [_session]);
      expect(const MrtTrackPushTokenReceived('tok').props, ['tok']);
      expect(const MrtBoardEtaTicked(9).props, [9]);
      for (final e in const <MrtTrackEvent>[
        MrtAlightPickCancelled(),
        MrtAlightTargetCleared(),
        MrtTrackWatchFailed(),
        MrtTrackWatchRecovered(),
        MrtTrackWatchLost(),
        MrtTrackCancelled(),
        MrtTrackRestored(),
      ]) {
        expect(e.props, isEmpty);
      }
      const req = MrtTrackRequested(
        carId: 'c',
        boardStationId: 'b',
        destStationId: 'd',
        targetStationId: 't',
        leadStops: 2,
      );
      expect(req.system, 'TRTC');
      expect(req.trainNumber, '');
      expect(req.boardEtaSeconds, isNull);
      expect(req.props, ['TRTC', '', null, 'c', 'b', 'd', 't', 2]);
    });

    test('metro eta events', () {
      expect(const LoadMetroEta('TRTC', 's').props, ['TRTC', 's']);
      expect(const MetroEtaArrived([_arrival]).props, [
        [_arrival],
      ]);
      expect(const MetroEtaFailed(OfflineError()).props, [
        const OfflineError(),
      ]);
      expect(const MetroEtaSettled().props, isEmpty);
      expect(const MetroEtaRecovered().props, isEmpty);
    });

    test('metro eta state', () {
      const sched = MetroSchedule(
        line: 'R',
        destination: 'X',
        firstTime: '06:00',
        lastTime: '00:10',
      );
      expect(sched.props, ['R', 'X', '06:00', '00:10']);
      expect(_arrival.props, ['R', 'X', 60, '', '', '', '', '', <int>[]]);
      MetroArrival arrivalOn(String system, String line) => MetroArrival(
        line: line,
        destination: 'X',
        estimateSeconds: 1,
        system: system,
      );
      expect(arrivalOn('TRTC', 'R').supportsAlightReminder, isTrue);
      expect(arrivalOn('TRTC', 'BR').supportsAlightReminder, isFalse);
      expect(arrivalOn('KRTC', 'R').supportsAlightReminder, isFalse);
      expect(arrivalOn('', 'BR').supportsAlightReminder, isFalse);
      const s = MetroEtaState();
      expect(s.loading, isFalse);
      expect(s.props, [<Object>[], <Object>[], false, null, null]);
      final at = DateTime(2026);
      final c = s.copyWith(
        arrivals: const [_arrival],
        schedule: const [sched],
        loading: true,
        error: const OfflineError(),
        updatedAt: at,
      );
      expect(c.arrivals, [_arrival]);
      expect(c.schedule, [sched]);
      expect(c.loading, isTrue);
      expect(c.error, const OfflineError());
      expect(c.updatedAt, at);
      expect(c.copyWith().error, const OfflineError());
      expect(c.copyWith().loading, isTrue);
      expect(c.copyWith(clearError: true).error, isNull);
      expect(c.copyWith(clearError: true).updatedAt, at);
      expect(
        c.copyWith(clearError: true, error: const UnknownError()).error,
        isNull,
      );
      expect(c.copyWith(loading: false).loading, isFalse);
    });
  });

  group('settings and feedback events', () {
    test('settings events carry their payload in props', () {
      expect(const AppearanceSelected(Appearance.dark).props, [
        Appearance.dark,
      ]);
      expect(const LanguageSelected(Language.en).props, [Language.en]);
      expect(const LiveActivityToggled(value: true).props, [true]);
      expect(const ShakeToReportToggled(value: false).props, [false]);
      expect(const PushToggled(value: true).props, [true]);
      expect(const FareTypeSelected(FareType.child).props, [FareType.child]);
      expect(const StepFreeRoutingToggled(value: true).props, [true]);
      expect(const WalkPaceSelected(WalkPace.faster).props, [WalkPace.faster]);
      expect(const UpdateCheckRequested().props, isEmpty);
      final at = DateTime(2026);
      expect(
        AppMetadataLoaded(appVersion: '1.0', powerSyncLastSyncedAt: at).props,
        ['1.0', at],
      );
    });

    test('feedback events', () {
      expect(const FeedbackOpened(screen: 's', locale: 'l').props, ['s', 'l']);
      expect(
        const FeedbackSubmitted(
          category: FeedbackCategory.eta,
          body: 'b',
        ).props,
        [FeedbackCategory.eta, 'b'],
      );
    });
  });

  group('settings state', () {
    test('defaults, copyWith and props', () {
      const s = SettingsState();
      expect(s.props, [
        Appearance.system,
        Language.system,
        true,
        false,
        FareType.full,
        true,
        true,
        false,
        WalkPace.standard,
        '',
        null,
        UpdateCheck.idle,
        '',
      ]);
      final at = DateTime(2026);
      final c = s.copyWith(
        appearance: Appearance.dark,
        language: Language.en,
        pushEnabled: false,
        pushUpdating: true,
        fareType: FareType.student,
        liveActivityEnabled: false,
        shakeToReport: false,
        stepFreeRouting: true,
        walkPace: WalkPace.faster,
        appVersion: '2',
        powerSyncLastSyncedAt: at,
        updateCheck: UpdateCheck.available,
        latestVersion: '3',
      );
      expect(c.props, [
        Appearance.dark,
        Language.en,
        false,
        true,
        FareType.student,
        false,
        false,
        true,
        WalkPace.faster,
        '2',
        at,
        UpdateCheck.available,
        '3',
      ]);
      expect(c.copyWith(), c);
    });

    test('enum lookups', () {
      expect(Appearance.fromKey('dark'), Appearance.dark);
      expect(Appearance.fromKey('zzz'), Appearance.system);
      expect(Language.fromKey('zh_CN'), Language.zhCn);
      expect(Language.fromKey(null), Language.system);
      expect(Language.system.locale, isNull);
      expect(Language.zhCn.locale, const Locale('zh', 'CN'));
      expect(Language.en.locale, const Locale('en'));
      expect(Language.zh.locale, const Locale('zh'));
      expect(WalkPace.fromCmPerSec(100), WalkPace.slower);
      expect(WalkPace.fromCmPerSec(180), WalkPace.faster);
      expect(WalkPace.fromCmPerSec(7), WalkPace.standard);
    });
  });
}
