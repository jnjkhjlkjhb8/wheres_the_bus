import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/fare_decoder.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/l10n/app_i18n_en.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

void main() {
  test(
    'persisted ticket keys remain stable and unknown values use full fare',
    () {
      const keys = {
        FareType.full: 'full',
        FareType.student: 'student',
        FareType.child: 'child',
        FareType.concession: 'concession',
      };
      for (final entry in keys.entries) {
        expect(entry.key.key, entry.value);
        expect(FareType.fromKey(entry.value), entry.key);
      }
      for (final key in [null, '', 'unknown', 'FULL', 'full ', '全票']) {
        expect(FareType.fromKey(key), FareType.full);
      }
    },
  );

  test('ticket labels use the corresponding localized rider category', () {
    for (final strings in <AppI18n>[AppI18nEn(), AppI18nZh()]) {
      expect(FareType.full.labelOf(strings), strings.fareFull);
      expect(FareType.student.labelOf(strings), strings.fareStudent);
      expect(FareType.child.labelOf(strings), strings.fareChild);
      expect(FareType.concession.labelOf(strings), strings.fareConcession);
    }
  });

  test('a generic bus half fare still belongs to the concession rider', () {
    const adult = (label: '全票', price: r'NT$30', fareClass: 1);
    const half = (label: '半票', price: r'NT$15', fareClass: 10);
    expect(
      pickFareRow([adult, half], FareType.concession),
      (row: half, matched: FareType.concession),
    );
    expect(
      pickFareRow([adult], FareType.concession),
      (row: adult, matched: FareType.full),
    );
  });

  test(
    'bus concessions prefer senior then disability then generic half fare',
    () {
      const adult = (label: '全票', price: r'NT$30', fareClass: 1);
      const half = (label: '半票', price: r'NT$15', fareClass: 10);
      const disability = (label: '愛心', price: r'NT$12', fareClass: 4);
      const senior = (label: '敬老', price: r'NT$14', fareClass: 3);
      expect(
        pickFareRow([adult, half, disability, senior], FareType.concession),
        (row: senior, matched: FareType.concession),
      );
      expect(
        pickFareRow([adult, half, disability], FareType.concession),
        (row: disability, matched: FareType.concession),
      );
    },
  );

  test('a published bus child fare takes priority over generic half fare', () {
    const adult = (label: '全票', price: r'NT$30', fareClass: 1);
    const half = (label: '半票', price: r'NT$12', fareClass: 10);
    const child = (label: '孩童', price: r'NT$14', fareClass: 7);
    expect(
      pickFareRow([adult, half, child], FareType.child),
      (row: child, matched: FareType.child),
    );
    expect(
      pickFareRow([adult, half], FareType.child),
      (row: half, matched: FareType.child),
    );
  });

  test('TRA disability fallback preserves the quoted rider category', () {
    const fares = [
      TraFare(ticketType: '成復', price: 63),
      TraFare(ticketType: '愛復', price: 31),
    ];
    expect(
      traFareFor(fares, '區間', FareType.concession),
      (price: 31, matched: FareType.concession),
    );
    expect(
      traFareFor([fares.first], '區間', FareType.concession),
      (price: 63, matched: FareType.full),
    );
  });

  test(
    'THSR student pays full fare while child and concession use half fare',
    () {
      const fares = [
        ThsrFare(fareClass: 1, price: 1490),
        ThsrFare(fareClass: 9, price: 745),
      ];
      for (final type in [FareType.full, FareType.student]) {
        expect(thsrFareFor(fares, type), (price: 1490, matched: FareType.full));
      }
      for (final type in [FareType.child, FareType.concession]) {
        expect(thsrFareFor(fares, type), (price: 745, matched: type));
        expect(
          thsrFareFor([fares.first], type),
          (price: 1490, matched: FareType.full),
        );
      }
    },
  );
}
