import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/thsr.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
  test('fares builds the Ask_Thsr request and decodes to domain fares', () {
    final client = _FakeThsrTimetableClient(
      response: thsa_fares(
        items: [
          thsa_fare(
            originStationId: '1000',
            destinationStationId: '1070',
            ticketType: 1,
            fareClass: 1,
            cabinClas: 1,
            price: 1490,
          ),
          thsa_fare(fareClass: 9, cabinClas: 1, price: 745),
        ],
      ),
    );
    final repo = ThsrRepository(timetableClient: client);

    return repo.fares('2026-07-09', '1000', '1070').then((fares) {
      expect(client.request?.originStationId, '1000');
      expect(client.request?.destinationStationId, '1070');
      expect(client.request?.date, '2026-07-09');
      // Domain type, not the proto thsa_fare, and every class survives — the
      // repository no longer decides which one is "the" fare.
      expect(fares, hasLength(2));
      expect(fares.first.price, 1490);
      expect(fares.first.fareClass, 1);
    });
  });

  test('resolves the rider ticket type against the decoded set', () {
    const fares = [
      ThsrFare(fareClass: 1, price: 1490),
      ThsrFare(fareClass: 9, price: 745),
      // 商務車廂: a different seat, not a different ticket type — it must never
      // stand in for the standard fare.
      ThsrFare(fareClass: 1, cabinClass: 2, price: 1950),
    ];

    expect(
      thsrFareFor(fares, FareType.full),
      (price: 1490, matched: FareType.full),
    );
    // THSR charges 孩童, 敬老 and 愛心 the same 半票.
    expect(
      thsrFareFor(fares, FareType.concession),
      (price: 745, matched: FareType.concession),
    );
    // THSR publishes no student fare, so students pay 全票 and are told so.
    expect(
      thsrFareFor(fares, FareType.student),
      (price: 1490, matched: FareType.full),
    );
  });
}

class _FakeThsrTimetableClient implements Thsr_timetable_serviceClient {
  _FakeThsrTimetableClient({required this.response});

  final thsa_fares response;
  Ask_Thsr? request;

  @override
  ResponseFuture<thsa_fares> fare(Ask_Thsr request, {CallOptions? options}) {
    this.request = request;
    return FakeResponseFuture(Future.value(response));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
