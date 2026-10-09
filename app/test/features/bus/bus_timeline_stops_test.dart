import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timeline_stops.dart';

import '../../support/helpers/i18n.dart';

// The approaching window uses AppConfig.getInt('eta_approaching_threshold_s'),
// which returns its registered default (30s) when Firebase is disabled — the
// state under test.
const _approachingThresholdSeconds = 30;

BusStopEtaViewModel _eta({
  String stopUid = 'stop',
  int direction = 0,
  int sequence = 1,
  int estimateSeconds = -1,
  String nextBusTime = '',
  int stopStatus = 1,
  String plate = '',
}) => BusStopEtaViewModel(
  stopUid: stopUid,
  direction: direction,
  sequence: sequence,
  estimateSeconds: estimateSeconds,
  nextBusTime: nextBusTime,
  stopStatus: stopStatus,
  vehiclePlates: const [],
  plate: plate,
);

BusStopModel _stop(String uid, int sequence, {String? name}) =>
    BusStopModel(stopUid: uid, stopName: name ?? uid, sequence: sequence);

void main() {
  group('timelineStopState', () {
    test('null ETA is none', () {
      expect(timelineStopState(null), TimelineStopState.none);
    });

    test('live bus at the stop is arriving', () {
      expect(
        timelineStopState(_eta(estimateSeconds: 0, stopStatus: 0)),
        TimelineStopState.arriving,
      );
    });

    test('estimate within the threshold is approaching', () {
      expect(
        timelineStopState(_eta(estimateSeconds: 20, stopStatus: 0)),
        TimelineStopState.approaching,
      );
      // Boundary: exactly at the threshold still counts.
      expect(
        timelineStopState(
          _eta(estimateSeconds: _approachingThresholdSeconds, stopStatus: 0),
        ),
        TimelineStopState.approaching,
      );
    });

    test('estimate past the threshold is none', () {
      expect(
        timelineStopState(
          _eta(estimateSeconds: _approachingThresholdSeconds + 1),
        ),
        TimelineStopState.none,
      );
      expect(
        timelineStopState(_eta(estimateSeconds: 600)),
        TimelineStopState.none,
      );
    });

    test('not-departed stop with no estimate is none', () {
      expect(timelineStopState(_eta()), TimelineStopState.none);
    });
  });

  group('retireStaleArriving', () {
    BusStopEtaViewModel arriving({String plate = ''}) =>
        _eta(estimateSeconds: 0, stopStatus: 0, plate: plate);

    TimelineStopState stateAt(List<BusStopEtaViewModel?> etas, int i) =>
        timelineStopState(retireStaleArriving(etas)[i]);

    test('same plate arriving twice keeps only the frontmost stop', () {
      final etas = [
        arriving(plate: 'ABC-123'),
        null,
        arriving(plate: 'ABC-123'),
      ];
      expect(stateAt(etas, 0), TimelineStopState.none);
      expect(stateAt(etas, 2), TimelineStopState.arriving);
    });

    test('different plates each keep their own arriving', () {
      final etas = [arriving(plate: 'ABC-123'), arriving(plate: 'XYZ-789')];
      expect(stateAt(etas, 0), TimelineStopState.arriving);
      expect(stateAt(etas, 1), TimelineStopState.arriving);
    });

    test('a plateless run collapses to its front', () {
      final etas = [arriving(), arriving(), arriving()];
      expect(stateAt(etas, 0), TimelineStopState.none);
      expect(stateAt(etas, 1), TimelineStopState.none);
      expect(stateAt(etas, 2), TimelineStopState.arriving);
    });

    test('non-adjacent plateless arrivals are both kept', () {
      final etas = [arriving(), _eta(estimateSeconds: 600), arriving()];
      expect(stateAt(etas, 0), TimelineStopState.arriving);
      expect(stateAt(etas, 2), TimelineStopState.arriving);
    });

    test('a retired entry shows no label rather than a service state', () {
      final retired = retireStaleArriving([
        arriving(plate: 'ABC-123'),
        arriving(plate: 'ABC-123'),
      ]);
      expect(retired.first!.displayLabelOf(zhStrings), isNull);
    });

    test('countdowns are untouched', () {
      final etas = [_eta(estimateSeconds: 120, stopStatus: 0)];
      expect(retireStaleArriving(etas), same(etas));
    });
  });

  group('fareSectionsBySequence', () {
    final stops = [_stop('a', 1), _stop('b', 2), _stop('c', 3), _stop('d', 4)];

    test('non-兩段票 pricing draws no bands', () {
      expect(
        fareSectionsBySequence(
          stops: stops,
          bufferSequences: {2},
          pricingType: 1,
        ),
        isEmpty,
      );
    });

    test('no buffer zone draws no bands', () {
      expect(
        fareSectionsBySequence(
          stops: stops,
          bufferSequences: const {},
          pricingType: 2,
        ),
        isEmpty,
      );
    });

    test('splits sections at the last buffer stop', () {
      expect(
        fareSectionsBySequence(
          stops: stops,
          bufferSequences: {2, 3},
          pricingType: 2,
        ),
        {1: 1, 2: 1, 3: 1, 4: 2},
      );
    });
  });

  group('deriveTimelineStops', () {
    test('emits every stop; one lacking an ETA gets no time, none state', () {
      final derived = deriveTimelineStops(
        i18n: zhStrings,
        stops: [_stop('a', 1), _stop('b', 2)],
        etaMap: {'seq:0:1': _eta(estimateSeconds: 120, stopStatus: 0)},
        direction: 0,
        bufferSequences: const {},
        pricingType: 0,
      );
      expect(derived.map((s) => s.uid), ['a', 'b']);
      expect(derived[0].primaryTime, '2分');
      expect(derived[1].primaryTime, isNull);
      expect(derived[1].state, TimelineStopState.none);
    });

    test('prefers the seq key then falls back to the uid key', () {
      final derived = deriveTimelineStops(
        i18n: zhStrings,
        stops: [_stop('a', 1), _stop('b', 2)],
        etaMap: {
          'seq:0:1': _eta(estimateSeconds: 120, stopStatus: 0),
          'uid:b': _eta(estimateSeconds: 300, stopStatus: 0),
        },
        direction: 0,
        bufferSequences: const {},
        pricingType: 0,
      );
      expect(derived.map((s) => s.uid), ['a', 'b']);
      expect(derived[1].primaryTime, '5分');
    });

    test('seq key is scoped to the requested direction', () {
      final derived = deriveTimelineStops(
        i18n: zhStrings,
        stops: [_stop('a', 1)],
        etaMap: {'seq:0:1': _eta(estimateSeconds: 120, stopStatus: 0)},
        direction: 1,
        bufferSequences: const {},
        pricingType: 0,
      );
      // No ETA under seq:1:1 or uid:a -> stop emitted but with no time.
      expect(derived.single.uid, 'a');
      expect(derived.single.primaryTime, isNull);
    });

    test('carries buffer flag and fare section onto stops', () {
      final derived = deriveTimelineStops(
        i18n: zhStrings,
        stops: [_stop('a', 1), _stop('b', 2), _stop('c', 3)],
        etaMap: {
          'seq:0:1': _eta(estimateSeconds: 120, stopStatus: 0),
          'seq:0:2': _eta(sequence: 2, estimateSeconds: 120, stopStatus: 0),
          'seq:0:3': _eta(sequence: 3, estimateSeconds: 120, stopStatus: 0),
        },
        direction: 0,
        bufferSequences: {2},
        pricingType: 2,
      );
      expect(derived.map((s) => s.fareSection), [1, 1, 2]);
      expect(derived.map((s) => s.isBuffer), [false, true, false]);
    });

    test('null stop list is handled as empty upstream contract', () {
      expect(
        deriveTimelineStops(
          i18n: zhStrings,
          stops: const [],
          etaMap: const {},
          direction: 0,
          bufferSequences: const {},
          pricingType: 0,
        ),
        isEmpty,
      );
    });
  });

  group('timelineEtaLabel', () {
    TimelineStop stopWith({
      TimelineStopState state = TimelineStopState.none,
      String? primaryTime,
    }) => TimelineStop(
      uid: 'u',
      name: 'n',
      state: state,
      primaryTime: primaryTime,
    );

    test('arriving/approaching state maps to its label', () {
      expect(
        timelineEtaLabel(stopWith(state: TimelineStopState.arriving)),
        TimelineEtaLabel.arriving,
      );
      expect(
        timelineEtaLabel(stopWith(state: TimelineStopState.approaching)),
        TimelineEtaLabel.approaching,
      );
    });

    test('no primary time is none', () {
      expect(timelineEtaLabel(stopWith()), TimelineEtaLabel.none);
    });

    test('0/1/2 countdown reads as countdownSoon', () {
      for (final t in ['0', '1', '2']) {
        expect(
          timelineEtaLabel(stopWith(primaryTime: t)),
          TimelineEtaLabel.countdownSoon,
        );
      }
    });

    test('other countdown values read as countdown', () {
      expect(
        timelineEtaLabel(stopWith(primaryTime: '3分')),
        TimelineEtaLabel.countdown,
      );
    });
  });
}
