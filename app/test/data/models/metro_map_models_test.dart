import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';

/// The drawn network: one row per map node, in the order the map paints them.
const _expected = <(String, String, double, double)>[
  ('BL01', '頂埔', 111, 1630.42),
  ('BL02', '永寧', 167, 1574),
  ('BL03', '土城', 223, 1521),
  ('BL04', '海山', 223, 1462),
  ('BL05', '亞東醫院', 223, 1406),
  ('BL06', '府中', 223, 1350),
  ('BL07', '板橋', 223, 1294),
  ('BL08', '新埔', 237, 1224),
  ('BL09', '江子翠', 291, 1190),
  ('BL10', '龍山寺', 367, 1164.55),
  ('BL11_G12', '西門', 419, 1142),
  ('BL12_R10', '台北車站', 490, 1098),
  ('BL13', '善導寺', 546, 1098),
  ('BL14_O07', '忠孝新生', 602, 1098),
  ('BL15_BR10', '忠孝復興', 658, 1098),
  ('BL16', '忠孝敦化', 714, 1098),
  ('BL17', '國父紀念館', 770, 1098),
  ('BL18', '市政府', 826, 1098),
  ('BL19', '永春', 882, 1098),
  ('BL20', '後山埤', 916, 1064),
  ('BL21', '昆陽', 952, 1040),
  ('BL22', '南港', 994, 1040),
  ('BL23_BR24', '南港展覽館', 1050, 1040),
  ('BR01', '動物園', 938, 1382),
  ('BR02', '木柵', 882, 1382),
  ('BR03', '萬芳醫院', 826, 1382),
  ('BR04', '萬芳社區', 776, 1378),
  ('BR05', '辛亥', 770, 1322),
  ('BR06', '麟光', 770, 1271),
  ('BR07', '六張犁', 714, 1266),
  ('BR08', '科技大樓', 658, 1241),
  ('BR12', '中山國中', 658, 921),
  ('BR13', '松山機場', 658, 862),
  ('BR14', '大直', 658, 806),
  ('BR15', '劍南路', 714, 778),
  ('BR16', '西湖', 770, 778),
  ('BR17', '港墘', 826, 778),
  ('BR18', '文德', 882, 778),
  ('BR19', '內湖', 938, 778),
  ('BR20', '大湖公園', 988, 812),
  ('BR21', '葫洲', 1022, 862),
  ('BR22', '東湖', 1050, 918),
  ('BR23', '南港軟體園區', 1050, 984),
  ('G01', '新店', 686, 1686.35),
  ('G02', '新店區公所', 686, 1630),
  ('G03', '七張', 686, 1576.8),
  ('G03A', '小碧潭', 630, 1576),
  ('G05', '景美', 686, 1462),
  ('G06', '萬隆', 686, 1406),
  ('G07', '公館', 658, 1350),
  ('G08', '台電大樓', 602, 1294),
  ('G09_O05', '古亭', 546, 1238),
  ('G10_R08', '中正紀念堂', 490, 1182),
  ('G11', '小南門', 436.8, 1181.85),
  ('G13', '北門', 419, 1070),
  ('G14_R11', '中山', 490, 1014),
  ('G15_O08', '松江南京', 602, 1014),
  ('G16_BR11', '南京復興', 658, 1014),
  ('G17', '台北小巨蛋', 714, 1014),
  ('G18', '南京三民', 770, 1014),
  ('G19', '松山', 826, 1014),
  ('O01', '南勢角', 434, 1501),
  ('O03', '永安市場', 433, 1392),
  ('O04', '頂溪', 433, 1336),
  ('O09', '行天宮', 602, 961),
  ('O10', '中山國小', 575.85, 901.41),
  ('O11_R13', '民權西路', 490, 902),
  ('O12', '大橋頭', 434, 901.6),
  ('O13', '台北橋', 364, 924),
  ('O14', '菜寮', 322, 966),
  ('O15', '三重', 280, 1010.55),
  ('O16', '先嗇宮', 240.8, 1052.8),
  ('O17_Y18', '頭前庄', 202, 1097),
  ('O18', '新莊', 162, 1136),
  ('O19', '輔大', 120, 1178),
  ('O20', '丹鳳', 81, 1218),
  ('O21', '迴龍', 45, 1257),
  ('O50', '三重國小', 364, 880),
  ('O51', '徐匯中學', 322, 840),
  ('O52', '三和國中', 280, 801),
  ('O53', '三民高中', 241, 765),
  ('O54', '蘆洲', 202, 730),
  ('R02', '象山', 826, 1182),
  ('R03', '台北101/世貿', 770, 1182),
  ('R04', '信義安和', 714, 1182),
  ('R05_BR09', '大安', 658, 1182),
  ('R06', '大安森林公園', 616, 1182),
  ('R07_O06', '東門', 574, 1182),
  ('R09', '台大醫院', 490, 1140.35),
  ('R12', '雙連', 490, 958),
  ('R14', '圓山', 490, 846),
  ('R15', '劍潭', 490, 790),
  ('R16', '士林', 490, 734),
  ('R17', '芝山', 490, 678),
  ('R18', '明德', 490, 622),
  ('R19', '石牌', 448, 580),
  ('R20', '唭哩岸', 406, 538),
  ('R21', '奇岩', 367, 496),
  ('R22', '北投', 322, 454),
  ('R22A', '新北投', 361, 426),
  ('R23', '復興崗', 266, 454),
  ('R24', '忠義', 210, 454),
  ('R25', '關渡', 154, 426),
  ('R26', '竹圍', 154, 370),
  ('R27', '紅樹林', 154, 314),
  ('R28', '淡水', 126, 258),
  ('Y07_G04', '大坪林', 686, 1520.68),
  ('Y08', '十四張', 630, 1518),
  ('Y09', '秀朗橋', 574, 1515),
  ('Y10', '景平', 518, 1462),
  ('Y11_O02', '景安', 433, 1448),
  ('Y12', '中和', 377, 1448),
  ('Y13', '橋和', 321, 1448.35),
  ('Y14', '中原', 304, 1392),
  ('Y15', '板新', 279, 1336),
  ('Y16', '板橋', 259, 1280),
  ('Y17', '新埔民生', 202, 1195),
  ('Y19', '幸福', 202, 1041),
  ('Y20', '新北產業園區', 202, 982),
];

void main() {
  group('MetroMapMode.fromName', () {
    test('resolves each declared mode by its name', () {
      expect(MetroMapMode.fromName('time'), MetroMapMode.time);
      expect(MetroMapMode.fromName('fare'), MetroMapMode.fare);
    });

    test('falls back to time for an absent or unknown name', () {
      expect(MetroMapMode.fromName(null), MetroMapMode.time);
      expect(MetroMapMode.fromName(''), MetroMapMode.time);
      expect(MetroMapMode.fromName('Fare'), MetroMapMode.time);
      expect(MetroMapMode.fromName('distance'), MetroMapMode.time);
    });

    test('keeps the declared order', () {
      expect(MetroMapMode.values, [MetroMapMode.time, MetroMapMode.fare]);
    });
  });

  test('the station table matches the drawn network node for node', () {
    expect(metroMapStations, hasLength(_expected.length));
    for (var i = 0; i < _expected.length; i++) {
      final (id, name, x, y) = _expected[i];
      final station = metroMapStations[i];
      expect(station.id, id, reason: 'row $i');
      expect(station.name, name, reason: id);
      expect(station.x, x, reason: id);
      expect(station.y, y, reason: id);
    }
  });

  group('lookup by name', () {
    test('a station name resolves to its node id', () {
      expect(metroStationIdForName('頂埔'), 'BL01');
      expect(metroStationIdForName('台北車站'), 'BL12_R10');
      expect(metroStationIdForName('新北產業園區'), 'Y20');
    });

    test('an unknown name resolves to nothing', () {
      expect(metroStationIdForName('不存在'), isNull);
      expect(metroStationIdForName(''), isNull);
    });

    test('every drawn name resolves to its own node', () {
      for (final station in metroMapStations) {
        final id = metroStationIdForName(station.name);
        expect(
          metroMapStations.firstWhere((s) => s.name == station.name).id,
          id,
        );
      }
    });
  });

  group('lookup by code', () {
    test('a plain code resolves to the station name', () {
      expect(metroStationName('BL01'), '頂埔');
      expect(metroStationName('Y20'), '新北產業園區');
    });

    test('an interchange resolves from every code it carries', () {
      expect(metroStationName('BL12'), '台北車站');
      expect(metroStationName('R10'), '台北車站');
      expect(metroStationName('G09'), '古亭');
      expect(metroStationName('O05'), '古亭');
      expect(metroStationName('Y07'), '大坪林');
      expect(metroStationName('G04'), '大坪林');
    });

    test('an unknown code resolves to nothing', () {
      expect(metroStationName('ZZ99'), isNull);
      expect(metroStationName(''), isNull);
      expect(metroStationName('BL12_R10'), isNull);
    });

    test('every drawn code maps back to a drawn station', () {
      for (final station in metroMapStations) {
        for (final code in station.id.split('_')) {
          expect(metroStationName(code), station.name, reason: code);
        }
      }
    });
  });
}
