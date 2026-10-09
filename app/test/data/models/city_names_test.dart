import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';

void main() {
  test('maps TDX codes to their Chinese names', () {
    expect(cityName('NewTaipei'), '新北市');
    expect(cityName('HsinchuCounty'), '新竹縣');
    // TDX ships the same county with and without the suffix.
    expect(cityName('Yilan'), cityName('YilanCounty'));
  });

  test('an unmapped code degrades to itself, not to a blank', () {
    expect(cityName('Atlantis'), 'Atlantis');
  });

  test('orders north to south, unmapped codes last', () {
    expect(cityOrder('Keelung'), lessThan(cityOrder('Taipei')));
    expect(cityOrder('Taipei'), lessThan(cityOrder('Kaohsiung')));
    expect(cityOrder('Kaohsiung'), lessThan(cityOrder('Atlantis')));
  });
}
