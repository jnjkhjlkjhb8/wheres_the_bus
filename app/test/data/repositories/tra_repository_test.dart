import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/tra.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
  test('fares packs the O/D pair into ask_staiton and decodes every class', () {
    final client = _FakeTraTimetableClient(
      response: tra_fare_items(
        items: [
          TraFareItem(ticketType: '成自', price: 99),
          TraFareItem(ticketType: '成復', price: 63),
        ],
      ),
    );
    final repo = TraRepository(timetableClient: client);

    // station_id carries the origin, date carries the destination id — matching
    // the router's Fare handler, which reuses ask_staiton to carry the O/D pair.
    return repo.fares('1080', '1000').then((fares) {
      expect(client.request?.stationId, '1080');
      expect(client.request?.date, '1000');
      // Domain type, not the proto TraFareItem. Every train class survives so
      // the caller can price its own train.
      expect(fares.map((f) => f.ticketType), ['成自', '成復']);
      expect(fares.map((f) => f.price), [99, 63]);
    });
  });

  test('timetable packs the date and O/D pair and decodes each row', () async {
    final client = _FakeTraTimetableClient(
      timetables: tra_timetables(
        items: [
          tra_timetable(
            trainNo: '123',
            trainTypeName: '自強',
            startingTime: '08:00:00',
            endingTime: '09:30:00',
            travelTime: '01:30',
            note: '備註',
          ),
        ],
      ),
    );
    final repo = TraRepository(timetableClient: client);

    final items = await repo.timetable('2026-07-09', '1000', '1080');

    expect(client.route?.date, '2026-07-09');
    expect(client.route?.originStationId, '1000');
    expect(client.route?.destinationStationId, '1080');
    expect(items.single.trainNo, '123');
    expect(items.single.trainType, '自強');
    expect(items.single.departureTime, '08:00:00');
    expect(items.single.travelMinutes, 90);
    expect(items.single.remark, '備註');
  });

  test(
    'stationBoard sends the direction wire value and decodes rows',
    () async {
      final client = _FakeTraTimetableClient(
        board: tra_station_board(
          items: [
            tra_station_departure(
              trainNo: '45',
              trainTypeName: '區間',
              destinationStationName: '七堵',
              departureTime: '10:05:00',
              trainDate: '2026-07-09',
            ),
          ],
        ),
      );
      final repo = TraRepository(timetableClient: client);

      final rows = await repo.stationBoard(
        stationId: '1000',
        date: '2026-07-09',
        after: '10:00:00',
        direction: RailBoardDirection.reverse,
      );

      expect(client.boardRequest?.stationId, '1000');
      expect(client.boardRequest?.date, '2026-07-09');
      expect(client.boardRequest?.after, '10:00:00');
      expect(client.boardRequest?.direction, 1);
      expect(rows.single.trainNo, '45');
      expect(rows.single.destination, '七堵');
      expect(rows.single.serviceDate, '2026-07-09');
    },
  );

  test('delay forwards the O/D request and maps train to minutes', () async {
    final client = _FakeTraTimetableClient(
      delays: [
        Resp_tra_delay(data: tra_delays(delay: [const MapEntry('123', 5)])),
      ],
    );
    final repo = TraRepository(timetableClient: client);

    final maps = await repo.delay('2026-07-09', '1000', '1080').toList();

    expect(client.route?.date, '2026-07-09');
    expect(client.route?.originStationId, '1000');
    expect(client.route?.destinationStationId, '1080');
    expect(maps, [
      {'123': 5},
    ]);
  });

  test(
    'stops asks the detain service for the train and decodes stops',
    () async {
      final detain = _FakeTraDetainClient(
        tra_stoptimes(
          items: [
            tra_stoptime(
              stationName: '臺北',
              stopSequence: 1,
              arrivalTime: '08:00:00',
              departureTime: '08:02:00',
            ),
          ],
        ),
      );
      final repo = TraRepository(detainClient: detain);

      final stops = await repo.stops('2026-07-09', '123');

      expect(detain.request?.date, '2026-07-09');
      expect(detain.request?.trainno, '123');
      expect(stops.single.stationName, '臺北');
      expect(stops.single.sequence, 1);
      expect(stops.single.departureTime, '08:02:00');
    },
  );
}

class _FakeTraDetainClient implements TRA_Detain_serviceClient {
  _FakeTraDetainClient(this.response);

  final tra_stoptimes response;
  ask_detain? request;

  @override
  ResponseFuture<tra_stoptimes> stops(
    ask_detain request, {
    CallOptions? options,
  }) {
    this.request = request;
    return FakeResponseFuture(Future.value(response));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _FakeTraTimetableClient implements TRA_timetable_serviceClient {
  _FakeTraTimetableClient({
    this.response,
    this.timetables,
    this.board,
    this.delays = const [],
  });

  final tra_fare_items? response;
  final tra_timetables? timetables;
  final tra_station_board? board;
  final List<Resp_tra_delay> delays;
  ask_staiton? request;
  ask_route? route;
  ask_station_board? boardRequest;

  @override
  ResponseFuture<tra_fare_items> fare(
    ask_staiton request, {
    CallOptions? options,
  }) {
    this.request = request;
    return FakeResponseFuture(Future.value(response!));
  }

  @override
  ResponseFuture<tra_timetables> timetable(
    ask_route request, {
    CallOptions? options,
  }) {
    route = request;
    return FakeResponseFuture(Future.value(timetables!));
  }

  @override
  ResponseFuture<tra_station_board> station_board(
    ask_station_board request, {
    CallOptions? options,
  }) {
    boardRequest = request;
    return FakeResponseFuture(Future.value(board!));
  }

  @override
  ResponseStream<Resp_tra_delay> delay(
    ask_route request, {
    CallOptions? options,
  }) {
    route = request;
    return FakeResponseStream(Stream.fromIterable(delays));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
