import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';

void main() {
  MetroMapStation byId(String id) =>
      metroMapStations.firstWhere((s) => s.id == id);

  test('station ids resolve to their official Taipei Metro names', () {
    // Regression guard for the previously scrambled id<->name pairings. Each
    // pair below is an official TDX (code, name) at its verified SVG circle.
    const cases = <String, String>{
      'BR12': '中山國中',
      'BR13': '松山機場',
      'BR14': '大直',
      'BR23': '南港軟體園區',
      'BL01': '頂埔',
      'BL02': '永寧',
      'BL11_G12': '西門',
      'G16_BR11': '南京復興',
      'G14_R11': '中山',
      'O01': '南勢角',
      'O11_R13': '民權西路',
      'O17_Y18': '頭前庄',
      'R09': '台大醫院',
      'R28': '淡水',
      'Y20': '新北產業園區',
    };
    for (final entry in cases.entries) {
      expect(
        byId(entry.key).name,
        entry.value,
        reason: '${entry.key} should be ${entry.value}',
      );
    }
  });

  test('malformed interchange ids were corrected', () {
    // 松江南京 (G15/O08), 東門 (R07/O06), 景安 (Y11/O02) — previously carried a
    // wrong second line code.
    expect(byId('G15_O08').name, '松江南京');
    expect(byId('R07_O06').name, '東門');
    expect(byId('Y11_O02').name, '景安');
    expect(metroMapStations.any((s) => s.id == 'G15_O18'), isFalse);
    expect(metroMapStations.any((s) => s.id == 'Y11_O12'), isFalse);
    expect(metroMapStations.any((s) => s.id == 'R07_O6'), isFalse);
  });

  test('every station id is unique', () {
    final ids = metroMapStations.map((s) => s.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });
}
