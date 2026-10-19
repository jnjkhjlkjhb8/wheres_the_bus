import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

void main() {
  test('both empty rail operators report no available rider quote', () {
    const quotes = [
      RailFareQuote.tra(fares: [], trainType: '區間'),
      RailFareQuote.thsr(fares: []),
    ];
    for (final quote in quotes) {
      expect(quote.isEmpty, isTrue);
      for (final type in FareType.values) {
        expect(quote.resolve(type), isNull);
      }
    }
  });

  test(
    'TRA quotes keep train class and rider fallback in the resolved fare',
    () {
      const fares = [
        TraFare(ticketType: '成自', price: 120),
        TraFare(ticketType: '成復', price: 80),
        TraFare(ticketType: '孩復', price: 40),
      ];
      const local = RailFareQuote.tra(fares: fares, trainType: '區間');
      const express = RailFareQuote.tra(fares: fares, trainType: '自強');
      expect(local.isEmpty, isFalse);
      expect(express.isEmpty, isFalse);
      expect(local.resolve(FareType.full), (price: 80, matched: FareType.full));
      expect(local.resolve(FareType.child), (
        price: 40,
        matched: FareType.child,
      ));
      expect(
        local.resolve(FareType.concession),
        (price: 80, matched: FareType.full),
      );
      expect(express.resolve(FareType.full), (
        price: 120,
        matched: FareType.full,
      ));
    },
  );

  test('THSR quotes preserve half fare and full fare fallback labels', () {
    const fares = [
      ThsrFare(fareClass: 1, price: 100),
      ThsrFare(fareClass: 9, price: 50),
    ];
    const quote = RailFareQuote.thsr(fares: fares);
    expect(quote.isEmpty, isFalse);
    for (final type in [FareType.child, FareType.concession]) {
      expect(quote.resolve(type), (price: 50, matched: type));
    }
    for (final type in [FareType.full, FareType.student]) {
      expect(quote.resolve(type), (price: 100, matched: FareType.full));
    }
    final adultOnly = RailFareQuote.thsr(fares: [fares.first]);
    expect(
      adultOnly.resolve(FareType.concession),
      (price: 100, matched: FareType.full),
    );
  });

  test(
    'TRA value equality keeps fare content, order, length and train class',
    () {
      final fares = [
        const TraFare(ticketType: '成復', price: 80),
        const TraFare(ticketType: '孩復', price: 40),
      ];
      final quote = RailFareQuote.tra(fares: fares, trainType: '區間');
      final equal = RailFareQuote.tra(
        fares: [
          for (final fare in fares)
            TraFare(ticketType: fare.ticketType, price: fare.price),
        ],
        trainType: '區間',
      );
      expect(identical(quote, equal), isFalse);
      expect(quote, equal);
      expect(quote.hashCode, equal.hashCode);
      final changed = [
        RailFareQuote.tra(fares: fares, trainType: '自強'),
        RailFareQuote.tra(fares: [fares.last, fares.first], trainType: '區間'),
        RailFareQuote.tra(fares: [fares.first], trainType: '區間'),
        RailFareQuote.tra(
          fares: [
            const TraFare(ticketType: '成復', price: 81),
            fares.last,
          ],
          trainType: '區間',
        ),
        RailFareQuote.tra(
          fares: [
            const TraFare(ticketType: '成自', price: 80),
            fares.last,
          ],
          trainType: '區間',
        ),
      ];
      for (final other in changed) {
        expect(quote, isNot(other));
      }
      expect({quote, equal, ...changed}, hasLength(1 + changed.length));
    },
  );

  test('THSR value equality keeps every fare entry and the rail operator', () {
    final fares = [
      const ThsrFare(fareClass: 1, price: 100),
      const ThsrFare(fareClass: 9, price: 50),
    ];
    final quote = RailFareQuote.thsr(fares: fares);
    final equal = RailFareQuote.thsr(
      fares: [
        for (final fare in fares)
          ThsrFare(
            fareClass: fare.fareClass,
            cabinClass: fare.cabinClass,
            price: fare.price,
          ),
      ],
    );
    expect(identical(quote, equal), isFalse);
    expect(quote, equal);
    expect(quote.hashCode, equal.hashCode);
    final changed = [
      RailFareQuote.thsr(fares: [fares.last, fares.first]),
      RailFareQuote.thsr(fares: [fares.first]),
      RailFareQuote.thsr(
        fares: [const ThsrFare(fareClass: 1, price: 101), fares.last],
      ),
      RailFareQuote.thsr(
        fares: [const ThsrFare(fareClass: 2, price: 100), fares.last],
      ),
      RailFareQuote.thsr(
        fares: [
          const ThsrFare(fareClass: 1, cabinClass: 2, price: 100),
          fares.last,
        ],
      ),
      const RailFareQuote.tra(
        fares: [TraFare(ticketType: '成自', price: 100)],
        trainType: '自強',
      ),
    ];
    for (final other in changed) {
      expect(quote, isNot(other));
    }
    expect({quote, equal, ...changed}, hasLength(1 + changed.length));
  });
}
