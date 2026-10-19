import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_state.dart';

void main() {
  const origin = RailStationSelection(name: 'A', id: '1');
  const destination = RailStationSelection(name: 'B', id: '2');

  group('events', () {
    test('RailSystemChanged compares the system', () {
      expect(
        const RailSystemChanged(RailSystem.tra),
        const RailSystemChanged(RailSystem.tra),
      );
      expect(
        const RailSystemChanged(RailSystem.tra),
        isNot(const RailSystemChanged(RailSystem.thsr)),
      );
    });

    test('RailStationSelection compares name and id', () {
      expect(origin, const RailStationSelection(name: 'A', id: '1'));
      expect(origin, isNot(const RailStationSelection(name: 'X', id: '1')));
      expect(origin, isNot(const RailStationSelection(name: 'A', id: '9')));
      expect(origin, isNot(const RailStationSelection(name: 'A')));
    });

    test('RailTimetableRequested compares every field', () {
      const base = RailTimetableRequested(
        system: RailSystem.tra,
        origin: origin,
        destination: destination,
        date: '2030-01-02',
        cutoffMinutes: 600,
      );
      expect(base.isDeparture, isTrue);
      expect(
        base,
        const RailTimetableRequested(
          system: RailSystem.tra,
          origin: origin,
          destination: destination,
          date: '2030-01-02',
          cutoffMinutes: 600,
        ),
      );
      const others = [
        RailTimetableRequested(
          system: RailSystem.thsr,
          origin: origin,
          destination: destination,
          date: '2030-01-02',
          cutoffMinutes: 600,
        ),
        RailTimetableRequested(
          system: RailSystem.tra,
          origin: destination,
          destination: destination,
          date: '2030-01-02',
          cutoffMinutes: 600,
        ),
        RailTimetableRequested(
          system: RailSystem.tra,
          origin: origin,
          destination: origin,
          date: '2030-01-02',
          cutoffMinutes: 600,
        ),
        RailTimetableRequested(
          system: RailSystem.tra,
          origin: origin,
          destination: destination,
          date: '2030-01-03',
          cutoffMinutes: 600,
        ),
        RailTimetableRequested(
          system: RailSystem.tra,
          origin: origin,
          destination: destination,
          date: '2030-01-02',
        ),
        RailTimetableRequested(
          system: RailSystem.tra,
          origin: origin,
          destination: destination,
          date: '2030-01-02',
          cutoffMinutes: 600,
          isDeparture: false,
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });

    test('RailTrainStopsRequested compares train and date', () {
      const base = RailTrainStopsRequested(trainNo: '123', date: 'd');
      expect(base, const RailTrainStopsRequested(trainNo: '123', date: 'd'));
      expect(
        base,
        isNot(const RailTrainStopsRequested(trainNo: '124', date: 'd')),
      );
      expect(
        base,
        isNot(const RailTrainStopsRequested(trainNo: '123', date: 'e')),
      );
    });

    test('RailDelaysUpdated compares the delays', () {
      expect(
        const RailDelaysUpdated({'1': 2}),
        const RailDelaysUpdated({'1': 2}),
      );
      expect(
        const RailDelaysUpdated({'1': 2}),
        isNot(const RailDelaysUpdated({'1': 3})),
      );
    });
  });

  group('RailState', () {
    test('RailInitial has no props', () {
      expect(const RailInitial().props, isEmpty);
      expect(const RailInitial(), const RailInitial());
    });

    test('RailTimetableLoading compares every field', () {
      const base = RailTimetableLoading(
        system: RailSystem.tra,
        originName: 'A',
        destName: 'B',
        date: 'd',
      );
      expect(
        base,
        const RailTimetableLoading(
          system: RailSystem.tra,
          originName: 'A',
          destName: 'B',
          date: 'd',
        ),
      );
      const others = [
        RailTimetableLoading(
          system: RailSystem.thsr,
          originName: 'A',
          destName: 'B',
          date: 'd',
        ),
        RailTimetableLoading(
          system: RailSystem.tra,
          originName: 'X',
          destName: 'B',
          date: 'd',
        ),
        RailTimetableLoading(
          system: RailSystem.tra,
          originName: 'A',
          destName: 'X',
          date: 'd',
        ),
        RailTimetableLoading(
          system: RailSystem.tra,
          originName: 'A',
          destName: 'B',
          date: 'x',
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });

    test('RailTimetableLoaded compares every field and copies selectively', () {
      const base = RailTimetableLoaded(
        system: RailSystem.tra,
        originName: 'A',
        destName: 'B',
        date: 'd',
      );
      const tra = TraTimetableItem(
        trainNo: '1',
        trainType: 't',
        departureTime: '08:00',
        arrivalTime: '09:00',
        travelMinutes: 60,
        delayMinutes: 0,
        hasBike: false,
        hasDiningCar: false,
        isDisabledFriendly: false,
        hasBreastfeeding: false,
        remark: '',
      );
      const thsr = ThsrTimetableItem(
        trainNo: '2',
        departureTime: '08:00',
        arrivalTime: '09:00',
        travelMinutes: 60,
        delayMinutes: 0,
        remark: '',
      );
      const quote = RailFareQuote.tra(fares: [], trainType: 'x');

      expect(base, base.copyWith());
      expect(base.copyWith(system: RailSystem.thsr).system, RailSystem.thsr);
      expect(base.copyWith(originName: 'X').originName, 'X');
      expect(base.copyWith(destName: 'X').destName, 'X');
      expect(base.copyWith(date: 'x').date, 'x');
      expect(base.copyWith(traItems: [tra]).traItems, [tra]);
      expect(base.copyWith(thsrItems: [thsr]).thsrItems, [thsr]);
      expect(base.copyWith(delays: {'1': 2}).delays, {'1': 2});
      expect(base.copyWith(fareQuote: quote).fareQuote, quote);

      final others = [
        base.copyWith(system: RailSystem.thsr),
        base.copyWith(originName: 'X'),
        base.copyWith(destName: 'X'),
        base.copyWith(date: 'x'),
        base.copyWith(traItems: [tra]),
        base.copyWith(thsrItems: [thsr]),
        base.copyWith(delays: {'1': 2}),
        base.copyWith(fareQuote: quote),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }

      final full = base.copyWith(
        traItems: [tra],
        thsrItems: [thsr],
        delays: {'1': 2},
        fareQuote: quote,
      );
      final kept = full.copyWith();
      expect(kept.traItems, [tra]);
      expect(kept.thsrItems, [thsr]);
      expect(kept.delays, {'1': 2});
      expect(kept.fareQuote, quote);
    });

    test('RailTrainStopsLoaded compares every field', () {
      const base = RailTrainStopsLoaded(
        system: RailSystem.tra,
        trainNo: '1',
        trainType: 't',
      );
      const stop = TraStopTime(
        stationName: 's',
        arrivalTime: '08:00',
        departureTime: '08:01',
        sequence: 1,
      );
      const thsrStop = ThsrStopTime(
        stationName: 's',
        arrivalTime: '08:00',
        departureTime: '08:01',
        sequence: 1,
      );
      expect(
        base,
        const RailTrainStopsLoaded(
          system: RailSystem.tra,
          trainNo: '1',
          trainType: 't',
        ),
      );
      const others = [
        RailTrainStopsLoaded(
          system: RailSystem.thsr,
          trainNo: '1',
          trainType: 't',
        ),
        RailTrainStopsLoaded(
          system: RailSystem.tra,
          trainNo: '2',
          trainType: 't',
        ),
        RailTrainStopsLoaded(
          system: RailSystem.tra,
          trainNo: '1',
          trainType: 'x',
        ),
        RailTrainStopsLoaded(
          system: RailSystem.tra,
          trainNo: '1',
          trainType: 't',
          traStops: [stop],
        ),
        RailTrainStopsLoaded(
          system: RailSystem.tra,
          trainNo: '1',
          trainType: 't',
          thsrStops: [thsrStop],
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });

    test('RailError compares the error', () {
      expect(const RailError(OfflineError()), const RailError(OfflineError()));
      expect(
        const RailError(OfflineError()),
        isNot(const RailError(TimeoutError())),
      );
    });
  });

  group('RailStationBoardState', () {
    const departure = RailStationDeparture(
      trainNo: '1',
      trainType: 't',
      destination: 'B',
      departureTime: '08:00:00',
      serviceDate: '2030-01-02',
    );

    test('every state carries its direction', () {
      expect(
        const RailStationBoardLoading(direction: RailBoardDirection.forward),
        const RailStationBoardLoading(direction: RailBoardDirection.forward),
      );
      expect(
        const RailStationBoardLoading(direction: RailBoardDirection.forward),
        isNot(
          const RailStationBoardLoading(direction: RailBoardDirection.reverse),
        ),
      );
    });

    test('Loaded compares departures, delays and delay time', () {
      final base = RailStationBoardLoaded(
        direction: RailBoardDirection.forward,
        departures: const [departure],
        delaysUpdatedAt: DateTime.utc(2030),
      );
      expect(
        base,
        RailStationBoardLoaded(
          direction: RailBoardDirection.forward,
          departures: const [departure],
          delaysUpdatedAt: DateTime.utc(2030),
        ),
      );
      final others = [
        RailStationBoardLoaded(
          direction: RailBoardDirection.reverse,
          departures: const [departure],
          delaysUpdatedAt: DateTime.utc(2030),
        ),
        RailStationBoardLoaded(
          direction: RailBoardDirection.forward,
          departures: const [],
          delaysUpdatedAt: DateTime.utc(2030),
        ),
        RailStationBoardLoaded(
          direction: RailBoardDirection.forward,
          departures: const [departure],
          delays: const {'1': 2},
          delaysUpdatedAt: DateTime.utc(2030),
        ),
        RailStationBoardLoaded(
          direction: RailBoardDirection.forward,
          departures: const [departure],
        ),
      ];
      for (final other in others) {
        expect(base, isNot(other));
      }
    });

    test('Loaded.copyWith swaps only what it is given', () {
      final base = RailStationBoardLoaded(
        direction: RailBoardDirection.reverse,
        departures: const [departure],
        delays: const {'1': 2},
        delaysUpdatedAt: DateTime.utc(2030),
      );
      final kept = base.copyWith();
      expect(kept, base);
      expect(kept.direction, RailBoardDirection.reverse);
      expect(kept.departures, const [departure]);
      expect(kept.delays, {'1': 2});
      expect(kept.delaysUpdatedAt, DateTime.utc(2030));
      final swapped = base.copyWith(
        delays: const {'1': 5},
        delaysUpdatedAt: DateTime.utc(2031),
      );
      expect(swapped.delays, {'1': 5});
      expect(swapped.delaysUpdatedAt, DateTime.utc(2031));
      expect(swapped.departures, const [departure]);
    });

    test('Failure compares direction and error', () {
      const base = RailStationBoardFailure(
        direction: RailBoardDirection.forward,
        error: OfflineError(),
      );
      expect(
        base,
        const RailStationBoardFailure(
          direction: RailBoardDirection.forward,
          error: OfflineError(),
        ),
      );
      expect(
        base,
        isNot(
          const RailStationBoardFailure(
            direction: RailBoardDirection.reverse,
            error: OfflineError(),
          ),
        ),
      );
      expect(
        base,
        isNot(
          const RailStationBoardFailure(
            direction: RailBoardDirection.forward,
            error: TimeoutError(),
          ),
        ),
      );
    });
  });
}
