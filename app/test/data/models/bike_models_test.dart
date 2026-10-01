import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';

void main() {
  test('BikeAvailability sums general and electric into available', () {
    const a = BikeAvailability(
      generalBikes: 3,
      electricBikes: 2,
      returnDocks: 7,
    );
    expect(a.available, 5);
    expect(a.returnDocks, 7);
  });
}
