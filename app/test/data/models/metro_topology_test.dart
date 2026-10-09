import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_topology.dart';
import 'package:wheres_the_bus/features/metro/data/mrt_car_binding.dart';

void main() {
  group('MetroTopology.aheadStations', () {
    test('板南線 台北車站 → 南港展覽館 lists the stations ahead in order', () {
      final ahead = MetroTopology.aheadStations(
        line: 'BL',
        boardCode: 'BL12',
        terminalCode: 'BL23',
      );
      final ids = ahead.map((s) => s.id).toList();
      // Board excluded, terminal included, strictly ascending.
      expect(ids.first, 'BL13');
      expect(ids.last, 'BL23');
      expect(ids.contains('BL12'), isFalse);
      // A representative alight (市政府 BL18) is on the path with its name.
      final target = ahead.firstWhere((s) => s.id == 'BL18');
      expect(target.name, '市政府');
      expect(target.line, 'BL');
    });

    test('中和新蘆線 蘆洲支線: 大橋頭 → 蘆洲 follows the O50..O54 spur', () {
      final ids = MetroTopology.aheadStations(
        line: 'O',
        boardCode: 'O12',
        terminalCode: 'O54',
      ).map((s) => s.id).toList();
      expect(ids, ['O50', 'O51', 'O52', 'O53', 'O54']);
    });

    test('中和新蘆線 迴龍方向: 大橋頭 → 迴龍 stays on the trunk, not the spur', () {
      final ids = MetroTopology.aheadStations(
        line: 'O',
        boardCode: 'O12',
        terminalCode: 'O21',
      ).map((s) => s.id).toList();
      expect(ids.first, 'O13');
      expect(ids.last, 'O21');
      expect(ids.contains('O50'), isFalse);
    });

    test('淡水信義線 新北投支線: 北投 → 新北投 is the single-hop R22A spur', () {
      final ids = MetroTopology.aheadStations(
        line: 'R',
        boardCode: 'R22',
        terminalCode: 'R22A',
      ).map((s) => s.id).toList();
      expect(ids, ['R22A']);
    });

    test('松山新店線 小碧潭支線: 七張 → 小碧潭 is the single-hop G03A spur', () {
      final ids = MetroTopology.aheadStations(
        line: 'G',
        boardCode: 'G03',
        terminalCode: 'G03A',
      ).map((s) => s.id).toList();
      expect(ids, ['G03A']);
    });

    test('an unresolved board/terminal pair yields no targets', () {
      expect(
        MetroTopology.aheadStations(
          line: 'BL',
          boardCode: '',
          terminalCode: 'BL23',
        ),
        isEmpty,
      );
    });
  });

  group('deriveCarIdFromCn1', () {
    test('prepends the position digit to the first half of the pair', () {
      expect(deriveCarIdFromCn1('163/164'), '1163');
    });

    test('preserves leading zeros', () {
      expect(deriveCarIdFromCn1('021/022'), '1021');
    });

    test('an empty or malformed pair falls back to empty (manual entry)', () {
      expect(deriveCarIdFromCn1(''), '');
      expect(deriveCarIdFromCn1('/164'), '');
    });
  });
}
