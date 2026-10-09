import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/tra.pbgrpc.dart';
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
}

class _FakeTraTimetableClient implements TRA_timetable_serviceClient {
  _FakeTraTimetableClient({required this.response});

  final tra_fare_items response;
  ask_staiton? request;

  @override
  ResponseFuture<tra_fare_items> fare(
    ask_staiton request, {
    CallOptions? options,
  }) {
    this.request = request;
    return FakeResponseFuture(Future.value(response));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
