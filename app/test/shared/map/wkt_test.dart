import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/map/wkt.dart';

void main() {
  test('parses MULTILINESTRING into lon/lat-swapped LatLng segments', () {
    final lines = parseWktLines(
      'MULTILINESTRING ((121.5 25.0, 121.6 25.1), (121.7 25.2, 121.8 25.3))',
    );
    expect(lines, hasLength(2));
    expect(lines[0][0].latitude, 25.0);
    expect(lines[0][0].longitude, 121.5);
    expect(lines[1].last.latitude, 25.3);
  });

  test('parses LINESTRING', () {
    final lines = parseWktLines('LINESTRING (121.5 25.0, 121.6 25.1)');
    expect(lines, hasLength(1));
    expect(lines[0], hasLength(2));
  });

  test('drops degenerate and malformed input', () {
    expect(parseWktLines(''), isEmpty);
    expect(parseWktLines('MULTILINESTRING ((121.5 25.0))'), isEmpty);
    expect(parseWktLines('garbage'), isEmpty);
  });
}
