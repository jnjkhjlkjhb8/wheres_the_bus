import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';

void main() {
  const arrival = MetroArrival(
    line: 'R',
    destination: 'A',
    estimateSeconds: 60,
  );
  const session = MrtTrackSession(
    trackId: 't',
    tripId: 'trip',
    carId: 'c',
    pathStationIds: ['R1'],
    pathStationNames: ['A'],
    targetIndex: 0,
    currentIndex: 0,
    remainingStops: 1,
    nextStationId: 'R1',
    nextStationName: 'A',
    progress: 0,
    status: MrtTrackStatus.tracking,
    leadStops: 1,
    system: 'TRTC',
  );

  const otherSession = MrtTrackSession(
    trackId: 'other',
    tripId: 'trip',
    carId: 'c',
    pathStationIds: ['R1'],
    pathStationNames: ['A'],
    targetIndex: 0,
    currentIndex: 0,
    remainingStops: 1,
    nextStationId: 'R1',
    nextStationName: 'A',
    progress: 0,
    status: MrtTrackStatus.tracking,
    leadStops: 1,
    system: 'TRTC',
  );

  group('MetroEtaEvent', () {
    test('events without payload carry no props', () {
      expect(const MetroEtaSettled().props, isEmpty);
      expect(const MetroEtaRecovered().props, isEmpty);
    });

    test('LoadMetroEta compares system and station', () {
      expect(
        const LoadMetroEta('TRTC', 'R1'),
        const LoadMetroEta('TRTC', 'R1'),
      );
      expect(
        const LoadMetroEta('TRTC', 'R1'),
        isNot(const LoadMetroEta('KRTC', 'R1')),
      );
      expect(
        const LoadMetroEta('TRTC', 'R1'),
        isNot(const LoadMetroEta('TRTC', 'R2')),
      );
    });

    test('MetroEtaArrived compares arrivals', () {
      expect(
        const MetroEtaArrived([arrival]),
        const MetroEtaArrived([arrival]),
      );
      expect(
        const MetroEtaArrived([arrival]),
        isNot(const MetroEtaArrived([])),
      );
    });

    test('MetroEtaFailed compares the error', () {
      expect(
        const MetroEtaFailed(OfflineError()),
        const MetroEtaFailed(OfflineError()),
      );
      expect(
        const MetroEtaFailed(OfflineError()),
        isNot(const MetroEtaFailed(TimeoutError())),
      );
    });
  });

  group('MetroEtaState values', () {
    test('MetroArrival compares every field and flags alight support', () {
      const base = MetroArrival(
        line: 'R',
        destination: 'A',
        estimateSeconds: 60,
        stationId: 's',
        destinationStationId: 'd',
        system: 'TRTC',
        trainNumber: 'n',
        cn1: 'c',
        congestion: [1],
      );
      expect(
        base,
        const MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
      );
      const others = [
        MetroArrival(
          line: 'G',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'B',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 61,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 'x',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'x',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'KRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'x',
          cn1: 'c',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'x',
          congestion: [1],
        ),
        MetroArrival(
          line: 'R',
          destination: 'A',
          estimateSeconds: 60,
          stationId: 's',
          destinationStationId: 'd',
          system: 'TRTC',
          trainNumber: 'n',
          cn1: 'c',
          congestion: [2],
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
      expect(base.supportsAlightReminder, isTrue);
      expect(others[0].supportsAlightReminder, isTrue);
      expect(others[5].supportsAlightReminder, isFalse);
      const bannan = MetroArrival(
        line: 'BR',
        destination: 'A',
        estimateSeconds: 1,
        system: 'TRTC',
      );
      expect(bannan.supportsAlightReminder, isFalse);
    });

    test('MetroSchedule compares every field', () {
      const base = MetroSchedule(
        line: 'R',
        destination: 'A',
        firstTime: '06:00',
        lastTime: '23:50',
      );
      expect(
        base,
        const MetroSchedule(
          line: 'R',
          destination: 'A',
          firstTime: '06:00',
          lastTime: '23:50',
        ),
      );
      const others = [
        MetroSchedule(
          line: 'G',
          destination: 'A',
          firstTime: '06:00',
          lastTime: '23:50',
        ),
        MetroSchedule(
          line: 'R',
          destination: 'B',
          firstTime: '06:00',
          lastTime: '23:50',
        ),
        MetroSchedule(
          line: 'R',
          destination: 'A',
          firstTime: '06:01',
          lastTime: '23:50',
        ),
        MetroSchedule(
          line: 'R',
          destination: 'A',
          firstTime: '06:00',
          lastTime: '23:51',
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });

    test('MetroEtaState copyWith swaps exactly what it is given', () {
      const base = MetroEtaState();
      expect(base.loading, isFalse);
      expect(base.error, isNull);
      expect(base.copyWith(), base);
      final stamp = DateTime.utc(2030);
      const schedule = MetroSchedule(
        line: 'R',
        destination: 'A',
        firstTime: '06:00',
        lastTime: '23:50',
      );
      final variants = [
        base.copyWith(arrivals: [arrival]),
        base.copyWith(schedule: [schedule]),
        base.copyWith(loading: true),
        base.copyWith(error: const OfflineError()),
        base.copyWith(updatedAt: stamp),
      ];
      for (final variant in variants) {
        expect(variant, isNot(base));
      }
      expect(variants[0].arrivals, [arrival]);
      expect(variants[1].schedule, [schedule]);
      expect(variants[2].loading, isTrue);
      expect(variants[3].error, isA<OfflineError>());
      expect(variants[4].updatedAt, stamp);

      final full = base.copyWith(
        arrivals: [arrival],
        schedule: [schedule],
        loading: true,
        error: const OfflineError(),
        updatedAt: stamp,
      );
      final kept = full.copyWith();
      expect(kept, full);
      expect(full.copyWith(clearError: true).error, isNull);
      expect(full.copyWith(clearError: true).arrivals, [arrival]);
    });
  });

  group('MrtTrackEvent', () {
    test('events without payload carry no props', () {
      expect(const MrtAlightPickCancelled().props, isEmpty);
      expect(const MrtAlightTargetCleared().props, isEmpty);
      expect(const MrtTrackWatchFailed().props, isEmpty);
      expect(const MrtTrackWatchRecovered().props, isEmpty);
      expect(const MrtTrackWatchLost().props, isEmpty);
      expect(const MrtTrackCancelled().props, isEmpty);
      expect(const MrtTrackRestored().props, isEmpty);
    });

    test('single-value events compare their value', () {
      expect(
        const MrtAlightPickStarted(arrival),
        const MrtAlightPickStarted(arrival),
      );
      expect(
        const MrtAlightPickStarted(arrival),
        isNot(
          const MrtAlightPickStarted(
            MetroArrival(line: 'G', destination: 'A', estimateSeconds: 60),
          ),
        ),
      );
      expect(
        const MrtAlightTargetPicked('a'),
        const MrtAlightTargetPicked('a'),
      );
      expect(
        const MrtAlightTargetPicked('a'),
        isNot(const MrtAlightTargetPicked('b')),
      );
      expect(const MrtAlightLeadChanged(1), const MrtAlightLeadChanged(1));
      expect(
        const MrtAlightLeadChanged(1),
        isNot(const MrtAlightLeadChanged(2)),
      );
      expect(const MrtTrackUpdated(session), const MrtTrackUpdated(session));
      expect(
        const MrtTrackUpdated(session),
        isNot(const MrtTrackUpdated(otherSession)),
      );
      expect(
        const MrtTrackPushTokenReceived('a'),
        const MrtTrackPushTokenReceived('a'),
      );
      expect(
        const MrtTrackPushTokenReceived('a'),
        isNot(const MrtTrackPushTokenReceived('b')),
      );
      expect(const MrtBoardEtaTicked(1), const MrtBoardEtaTicked(1));
      expect(const MrtBoardEtaTicked(1), isNot(const MrtBoardEtaTicked(2)));
    });

    test('MrtTrackRequested compares every field', () {
      const base = MrtTrackRequested(
        carId: 'c',
        boardStationId: 'b',
        destStationId: 'd',
        targetStationId: 't',
        leadStops: 1,
        trainNumber: 'n',
        boardEtaSeconds: 30,
      );
      expect(base.system, 'TRTC');
      expect(
        base,
        const MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
      );
      const others = [
        MrtTrackRequested(
          carId: 'x',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'x',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'x',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 'x',
          leadStops: 1,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 2,
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          system: 'KRTC',
          trainNumber: 'n',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'x',
          boardEtaSeconds: 30,
        ),
        MrtTrackRequested(
          carId: 'c',
          boardStationId: 'b',
          destStationId: 'd',
          targetStationId: 't',
          leadStops: 1,
          trainNumber: 'n',
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });
  });
}
