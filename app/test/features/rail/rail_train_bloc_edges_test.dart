import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

const _stops = [
  TraStopTime(
    stationName: '台北',
    arrivalTime: '',
    departureTime: '08:00',
    sequence: 1,
  ),
  TraStopTime(
    stationName: '板橋',
    arrivalTime: '08:10',
    departureTime: '08:11',
    sequence: 2,
  ),
  TraStopTime(
    stationName: '台中',
    arrivalTime: '09:00',
    departureTime: '',
    sequence: 3,
  ),
];

class _Tra implements TraRepository {
  _Tra({this.stopsResult = _stops});

  List<TraStopTime> stopsResult;
  Completer<void>? stopsGate;
  final prices = <(String, String), int>{};
  final delayControllers = <StreamController<Map<String, int>>>[];

  @override
  Future<List<TraStopTime>> stops(String date, String trainNo) async {
    await stopsGate?.future;
    return stopsResult;
  }

  @override
  Future<List<TraFare>> fares(String origin, String destination) async {
    final price = prices[(origin, destination)];
    if (price == null) throw StateError('no fare');
    return [TraFare(ticketType: '成自', price: price)];
  }

  @override
  Stream<Map<String, int>> delay(String date, String origin, String dest) {
    final c = StreamController<Map<String, int>>();
    delayControllers.add(c);
    return c.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _Thsr implements ThsrRepository {
  @override
  Future<List<ThsrStopTime>> stops(String date, String trainNo) async => const [
    ThsrStopTime(
      stationName: '南港',
      arrivalTime: '',
      departureTime: '08:00',
      sequence: 1,
    ),
    ThsrStopTime(
      stationName: '左營',
      arrivalTime: '09:30',
      departureTime: '',
      sequence: 2,
    ),
  ];

  @override
  Future<List<ThsrFare>> fares(String d, String o, String x) async => const [
    ThsrFare(fareClass: 1, price: 1490),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

RailTrainBloc _bloc(
  _Tra tra, {
  String type = '自強',
  String? origin,
  String? dest,
}) => RailTrainBloc(
  type: type,
  trainNo: '123',
  date: '2030-01-02',
  userOrigin: origin,
  userDest: dest,
  tra: tra,
  thsr: _Thsr(),
);

Future<RailTrainState> _loaded(RailTrainBloc b) =>
    b.stream.firstWhere((s) => s.status == RailTrainStatus.loaded);

void main() {
  test('the full run and the rider segment keep their own fares', () async {
    final tra = _Tra()
      ..prices[('台北', '台中')] = 300
      ..prices[('板橋', '台中')] = 100;
    final b = _bloc(tra, origin: '板橋', dest: '台中');
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    final s = await _loaded(b);
    expect(s.fullFare!.resolve(FareType.full)?.price, 300);
    expect(s.userFare!.resolve(FareType.full)?.price, 100);
  });

  for (final (origin, dest) in [('板橋', null), (null, '台中')]) {
    test(
      'a half-specified segment ($origin, $dest) quotes only the full run',
      () {
        final tra = _Tra()..prices[('台北', '台中')] = 300;
        final b = _bloc(tra, origin: origin, dest: dest);
        addTearDown(b.close);
        b.add(const RailTrainStarted());
        return _loaded(b).then((s) {
          expect(s.fullFare!.resolve(FareType.full)?.price, 300);
          expect(s.userFare, isNull);
        });
      },
    );
  }

  test('THSR runs never touch the TRA delay feed', () async {
    final tra = _Tra();
    final b = _bloc(tra, type: '高鐵');
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    await _loaded(b);
    await pumpEventQueue();
    expect(tra.delayControllers, isEmpty);
  });

  test('a one-stop TRA run does not subscribe to delays', () async {
    final tra = _Tra(stopsResult: [_stops.first])..prices[('台北', '台北')] = 1;
    final b = _bloc(tra);
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    await _loaded(b);
    await pumpEventQueue();
    expect(tra.delayControllers, isEmpty);
  });

  test('restarting drops the previous delay subscription', () async {
    final tra = _Tra()..prices[('台北', '台中')] = 300;
    final b = _bloc(tra);
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    await _loaded(b);
    await pumpEventQueue();
    expect(tra.delayControllers, hasLength(1));
    expect(tra.delayControllers.first.hasListener, isTrue);

    b.add(const RailTrainStarted());
    await pumpEventQueue();
    expect(tra.delayControllers, hasLength(2));
    expect(tra.delayControllers.first.hasListener, isFalse);
    expect(tra.delayControllers.last.hasListener, isTrue);
  });

  test('closing cancels the delay subscription', () async {
    final tra = _Tra()..prices[('台北', '台中')] = 300;
    final b = _bloc(tra);
    b.add(const RailTrainStarted());
    await _loaded(b);
    await pumpEventQueue();
    expect(tra.delayControllers.single.hasListener, isTrue);
    await b.close();
    expect(tra.delayControllers.single.hasListener, isFalse);
  });

  test('a restart resets to the loading state before the new load', () async {
    final tra = _Tra()..prices[('台北', '台中')] = 300;
    final b = _bloc(tra);
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    await _loaded(b);

    final gate = tra.stopsGate = Completer<void>();
    b.add(const RailTrainStarted());
    await pumpEventQueue();
    expect(b.state, const RailTrainState());
    gate.complete();
    await _loaded(b);
  });
}
