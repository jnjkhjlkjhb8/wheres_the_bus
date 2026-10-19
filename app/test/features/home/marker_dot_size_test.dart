import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/widgets/home_marker_style.dart';

void main() {
  test('the large-zoom-band dot is bigger than the small-zoom-band dot', () {
    final large = dotMarkerSize(MarkerStyle.largeDot);
    final small = dotMarkerSize(MarkerStyle.smallDot);

    expect(large, greaterThan(small));
  });
}
