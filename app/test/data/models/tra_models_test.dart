import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

void main() {
  // What TDX lands for 桃園→臺北: one adult fare per train class, plus the
  // concession rows for the classes that publish them.
  const fares = [
    TraFare(ticketType: '成自', price: 99),
    TraFare(ticketType: '成莒', price: 76),
    TraFare(ticketType: '成復', price: 63),
    TraFare(ticketType: '成普', price: 31),
    TraFare(ticketType: '孩自', price: 50),
    TraFare(ticketType: '敬復', price: 32),
  ];

  test('prices each train class from its TDX train type name', () {
    int? full(String trainType) =>
        traFareFor(fares, trainType, FareType.full)?.price;
    // 區間車 is priced on the 復興 (成復) tier — the fare that used to be
    // misquoted as 99 because the pair's priciest row won.
    expect(full('區間'), 63);
    expect(full('區間快'), 63);
    expect(full('莒光(郵輪式列車)'), 76);
    expect(full('普快(專開列車)'), 31);
    // 太魯閣/普悠瑪/EMU3000 all bill at the 自強 fare.
    expect(full('自強(3000)(EMU3000 型電車)'), 99);
    expect(full('太魯閣(太魯閣)'), 99);
    expect(full('普悠瑪(普悠瑪)'), 99);
  });

  test('quotes the rider ticket type on the matching train class', () {
    // The concession is resolved on *both* axes at once: 敬老 on a 區間車 is
    // 敬復 (32), not the 敬老自強 fare and not the 全票區間 fare.
    final senior = traFareFor(fares, '區間', FareType.concession);
    expect(senior, (price: 32, matched: FareType.concession));

    final child = traFareFor(fares, '自強', FareType.child);
    expect(child, (price: 50, matched: FareType.child));
  });

  test('falls back to the full fare and says so', () {
    // The pair publishes no 孩童 fare on 區間車, so the rider sees the full
    // fare — reported as 全票 so the UI can never label 63 as a child fare.
    final child = traFareFor(fares, '區間', FareType.child);
    expect(child, (price: 63, matched: FareType.full));

    // TRA prices no student fare at all; students ride on 全票.
    final student = traFareFor(fares, '區間', FareType.student);
    expect(student, (price: 63, matched: FareType.full));
  });

  test('returns null when the pair has no fare for that class', () {
    expect(traFareFor(const [], '區間', FareType.full), isNull);
    // A zero price is missing data, not a free ride.
    expect(
      traFareFor(
        const [TraFare(ticketType: '成復', price: 0)],
        '區間',
        FareType.full,
      ),
      isNull,
    );
  });
}
