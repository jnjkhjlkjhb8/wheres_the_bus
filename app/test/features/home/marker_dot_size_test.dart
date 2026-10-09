import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';

void main() {
  test('the large-zoom-band dot is bigger than the small-zoom-band dot', () {
    final large = dotMarkerSizeForTest(large: true);
    final small = dotMarkerSizeForTest(large: false);

    expect(large, greaterThan(small));
  });
}
