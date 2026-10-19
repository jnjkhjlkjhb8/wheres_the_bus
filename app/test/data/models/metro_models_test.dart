import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';

MetroLiveArrival arrival({
  String line = 'BL',
  String destination = '南港展覽館',
  int estimateSeconds = 120,
  String stationId = 'BL12',
  String destinationStationId = 'BL23',
  String system = 'TRTC',
  String trainNumber = '101',
  String cn1 = '163/164',
  List<int> congestion = const [1, 2, 3],
}) => MetroLiveArrival(
  line: line,
  destination: destination,
  estimateSeconds: estimateSeconds,
  stationId: stationId,
  destinationStationId: destinationStationId,
  system: system,
  trainNumber: trainNumber,
  cn1: cn1,
  congestion: congestion,
);

MetroScheduleEntry schedule({
  String line = 'BL',
  String destination = 'BL23',
  String firstTime = '05:50:00',
  String lastTime = '23:59:00',
}) => MetroScheduleEntry(
  line: line,
  destination: destination,
  firstTime: firstTime,
  lastTime: lastTime,
);

void main() {
  test(
    'unpaired arrivals expose empty optional tracking and congestion data',
    () {
      const value = MetroLiveArrival(
        line: 'BL',
        destination: '南港展覽館',
        estimateSeconds: 120,
      );
      expect(value.line, 'BL');
      expect(value.destination, '南港展覽館');
      expect(value.estimateSeconds, 120);
      expect(value.stationId, isEmpty);
      expect(value.destinationStationId, isEmpty);
      expect(value.system, isEmpty);
      expect(value.trainNumber, isEmpty);
      expect(value.cn1, isEmpty);
      expect(value.congestion, isEmpty);
    },
  );

  test('arrival values deduplicate equal content from distinct objects', () {
    final first = arrival(congestion: [1, 2, 3]);
    final equal = arrival(congestion: [1, 2, 3]);
    expect(identical(first, equal), isFalse);
    expect(identical(first.congestion, equal.congestion), isFalse);
    expect(equal, first);
    expect(equal.hashCode, first.hashCode);
    expect({first, equal}, hasLength(1));
  });

  test('every arrival field contributes to its value identity', () {
    final first = arrival();
    final different = [
      arrival(line: 'R'),
      arrival(destination: '頂埔'),
      arrival(estimateSeconds: 121),
      arrival(stationId: 'BL11'),
      arrival(destinationStationId: 'BL01'),
      arrival(system: 'KRTC'),
      arrival(trainNumber: '102'),
      arrival(cn1: '165/166'),
      arrival(congestion: [1, 3, 3]),
      arrival(congestion: [3, 2, 1]),
      arrival(congestion: [1, 2, 3, 1]),
    ];
    for (final value in different) {
      expect(value, isNot(first));
    }
    expect({first, ...different}, hasLength(12));
  });

  test(
    'schedule rows preserve their published line, terminal and time values',
    () {
      final value = MetroScheduleEntry.fromRow(const {
        'lineid': 'BL',
        'destinationstaionid': 'BL23',
        'first_train_time': '05:50:00',
        'last_train_time': '23:59:00',
      });
      expect(value.line, 'BL');
      expect(value.destination, 'BL23');
      expect(value.firstTime, '05:50:00');
      expect(value.lastTime, '23:59:00');
      expect(value, schedule());
    },
  );

  test(
    'schedule values compare equal and deduplicate across distinct objects',
    () {
      final first = schedule();
      final equal = schedule();
      expect(identical(first, equal), isFalse);
      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect({first, equal}, hasLength(1));
    },
  );

  test('every schedule field changes its value identity', () {
    final first = schedule();
    final different = [
      schedule(line: 'R'),
      schedule(destination: 'BL01'),
      schedule(firstTime: '06:00:00'),
      schedule(lastTime: '00:01:00'),
    ];
    for (final value in different) {
      expect(value, isNot(first));
    }
    expect({first, ...different}, hasLength(5));
  });
}
