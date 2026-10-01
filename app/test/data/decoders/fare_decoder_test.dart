import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/fare_decoder.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';

import '../../support/helpers/i18n.dart';

BusFareInfo fareWith(String json) => BusFareInfo(
  pricingType: 0,
  isFreeBus: false,
  sectionFaresJson: utf8.encode(json),
  stageFaresJson: const [],
  odFaresJson: const [],
);

const _emptyFare = BusFareInfo(
  pricingType: 0,
  isFreeBus: false,
  sectionFaresJson: [],
  stageFaresJson: [],
  odFaresJson: [],
);

void main() {
  test('extracts buffer stop sequences across sections', () {
    final fare = fareWith(
      jsonEncode([
        {
          'BufferZones': [
            {'StopSequence': 3},
            {'StopSequence': 7},
          ],
        },
        {
          'BufferZones': [
            {'StopSequence': 3},
          ],
        },
      ]),
    );
    expect(decodeBufferSequences(fare), {3, 7});
  });

  test('null fare yields empty set', () {
    expect(decodeBufferSequences(null), isEmpty);
  });

  test('empty payload yields empty set', () {
    expect(decodeBufferSequences(_emptyFare), isEmpty);
  });

  test('malformed json yields empty set', () {
    expect(decodeBufferSequences(fareWith('not json')), isEmpty);
  });

  test('non-list payload yields empty set', () {
    expect(decodeBufferSequences(fareWith('{"a":1}')), isEmpty);
  });

  test('sections without valid buffer zones are skipped', () {
    final fare = fareWith(
      jsonEncode([
        {'Other': 1},
        {'BufferZones': 'nope'},
        {
          'BufferZones': [
            {'StopSequence': 'x'},
            {'StopSequence': 5},
          ],
        },
      ]),
    );
    expect(decodeBufferSequences(fare), {5});
  });

  group('decodeFareTable', () {
    List<Object?> dump(List<FareGroup> groups) => [
      for (final g in groups)
        [
          g.segment,
          [for (final r in g.rows) '${r.label} ${r.price}'],
        ],
    ];

    BusFareInfo stageFare(String json) => BusFareInfo(
      pricingType: 2,
      isFreeBus: false,
      sectionFaresJson: const [],
      stageFaresJson: utf8.encode(json),
      odFaresJson: const [],
    );

    test('single section: one flat group, headline classes first', () {
      final fare = fareWith(
        jsonEncode([
          {
            'Fares': [
              {'FareClass': 3, 'TicketType': 1, 'Price': 8},
              {'FareClass': 1, 'TicketType': 1, 'Price': 15},
            ],
          },
        ]),
      );
      expect(dump(decodeFareTable(zhStrings, fare)), [
        [
          null,
          [r'全票 NT$15', r'敬老票 NT$8'],
        ],
      ]);
    });

    test('splits a class by ticket type only when the price differs', () {
      final fare = fareWith(
        jsonEncode([
          {
            'Fares': [
              {'FareClass': 1, 'TicketType': 1, 'Price': 15},
              {'FareClass': 1, 'TicketType': 3, 'Price': 15},
              {'FareClass': 2, 'TicketType': 1, 'Price': 15},
              {'FareClass': 2, 'TicketType': 3, 'Price': 12},
            ],
          },
        ]),
      );
      expect(dump(decodeFareTable(zhStrings, fare)), [
        [
          null,
          [r'全票 NT$15', r'學生票 NT$15', r'學生票 · 電子票證 NT$12'],
        ],
      ]);
    });

    test('stage fares yield one origin→destination group each', () {
      final fare = stageFare(
        jsonEncode([
          {
            'OriginStage': {'StopName': '大竹消防隊', 'Sequence': 1},
            'DestinationStage': {'StopName': '庫倫街口', 'Sequence': 10},
            'Fares': [
              {'FareName': '全票_不分時段_三排座', 'FareClass': 1, 'Price': 83},
              {'FareName': '半票_不分時段_三排座', 'FareClass': 10, 'Price': 42},
            ],
          },
        ]),
      );
      expect(dump(decodeFareTable(zhStrings, fare)), [
        [
          '大竹消防隊 → 庫倫街口',
          [r'全票 NT$83', r'半票 NT$42'],
        ],
      ]);
    });

    test('drops -1 (no fare) and non-positive prices', () {
      final fare = fareWith(
        jsonEncode([
          {
            'Fares': [
              {'FareClass': 1, 'Price': -1},
              {'FareClass': 10, 'Price': 0},
            ],
          },
        ]),
      );
      expect(decodeFareTable(zhStrings, fare), isEmpty);
    });

    test('unknown fare class falls back to a numbered label', () {
      final fare = fareWith(
        jsonEncode([
          {
            'Fares': [
              {'FareClass': 99, 'Price': 20},
            ],
          },
        ]),
      );
      expect(dump(decodeFareTable(zhStrings, fare)), [
        [
          null,
          [r'票種 99 NT$20'],
        ],
      ]);
    });

    test('null and malformed payloads yield empty', () {
      expect(decodeFareTable(zhStrings, null), isEmpty);
      expect(decodeFareTable(zhStrings, fareWith('not json')), isEmpty);
      expect(decodeFareTable(zhStrings, _emptyFare), isEmpty);
    });
  });

  group('decodeOdFares', () {
    BusFareInfo odFare(String json) => BusFareInfo(
      pricingType: 1,
      isFreeBus: false,
      sectionFaresJson: const [],
      stageFaresJson: const [],
      odFaresJson: utf8.encode(json),
    );

    List<Object?> dump(List<OdOrigin> origins) => [
      for (final o in origins)
        [
          o.origin,
          [
            for (final d in o.destinations)
              [
                d.destination,
                [for (final r in d.rows) '${r.label} ${r.price}'],
              ],
          ],
        ],
    ];

    final sample = odFare(
      jsonEncode([
        {
          'OriginStop': {'StopName': '統領百貨'},
          'DestinationStop': {'StopName': '慈文國中'},
          'Fares': [
            {'FareClass': 1, 'Price': 18},
          ],
        },
        {
          'OriginStop': {'StopName': '統領百貨'},
          'DestinationStop': {'StopName': '溪洲'},
          'Fares': [
            {'FareClass': 1, 'Price': 27},
          ],
        },
        {
          'OriginStop': {'StopName': '中正橋'},
          'DestinationStop': {'StopName': '崁下'},
          'Fares': [
            {'FareClass': 1, 'Price': 31},
          ],
        },
      ]),
    );

    test('groups destinations under their boarding stop, preserving order', () {
      expect(dump(decodeOdFares(zhStrings, sample)), [
        [
          '統領百貨',
          [
            [
              '慈文國中',
              [r'全票 NT$18'],
            ],
            [
              '溪洲',
              [r'全票 NT$27'],
            ],
          ],
        ],
        [
          '中正橋',
          [
            [
              '崁下',
              [r'全票 NT$31'],
            ],
          ],
        ],
      ]);
    });

    test('entries missing an endpoint are skipped', () {
      final fare = odFare(
        jsonEncode([
          {
            'DestinationStop': {'StopName': '崁下'},
            'Fares': [
              {'FareClass': 1, 'Price': 31},
            ],
          },
        ]),
      );
      expect(decodeOdFares(zhStrings, fare), isEmpty);
    });

    test('flat city-bus fares (no OD payload) yield no origins', () {
      expect(decodeOdFares(zhStrings, fareWith('[{"Fares":[]}]')), isEmpty);
      expect(decodeOdFares(zhStrings, null), isEmpty);
    });

    test('odFareRange spans cheapest to dearest across origins', () {
      expect(
        odFareRange(decodeOdFares(zhStrings, sample), FareType.full),
        (min: 18, max: 31),
      );
    });

    test('odFareRange is null when there are no priced rows', () {
      expect(odFareRange(const [], FareType.full), isNull);
    });
  });

  group('pickFareRow', () {
    // A 公路客運 segment as TDX publishes it: 全票, 半票, plus the concessions
    // that carry their own class codes.
    const rows = <FareRow>[
      (label: '全票', price: r'NT$30', fareClass: 1),
      (label: '半票', price: r'NT$15', fareClass: 10),
      (label: '學生票', price: r'NT$24', fareClass: 2),
      (label: '敬老票', price: r'NT$12', fareClass: 3),
    ];

    test('picks the class matching the rider ticket type', () {
      expect(pickFareRow(rows, FareType.full)?.row.price, r'NT$30');
      expect(pickFareRow(rows, FareType.student)?.row.price, r'NT$24');
      expect(pickFareRow(rows, FareType.concession)?.row.price, r'NT$12');
      // 孩童 has no class 7 row here, so it falls to 半票 — a genuine child
      // price, so it stays labelled as the rider's own type.
      final child = pickFareRow(rows, FareType.child);
      expect(child?.row.price, r'NT$15');
      expect(child?.matched, FareType.child);
    });

    test('reports a fall back to 全票 as 全票', () {
      const fullOnly = <FareRow>[
        (label: '全票', price: r'NT$30', fareClass: 1),
      ];
      final senior = pickFareRow(fullOnly, FareType.concession);
      // The number is the full fare, so it must not be labelled 敬老  愛心票 —
      // that would quote a discount the operator never published.
      expect(senior, (row: fullOnly.first, matched: FareType.full));
    });

    test('null only when the segment prices nothing at all', () {
      expect(pickFareRow(const [], FareType.full), isNull);
      // An unmapped class code is still a real price; quoting it beats
      // showing the rider a blank where a fare belongs.
      const unmapped = <FareRow>[
        (label: '票種 99', price: r'NT$40', fareClass: 99),
      ];
      expect(pickFareRow(unmapped, FareType.full)?.row.price, r'NT$40');
    });
  });
}
