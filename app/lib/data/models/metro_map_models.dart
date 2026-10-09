enum MetroMapMode {
  time,
  fare;

  /// Falls back to [time] — the map's default — for an absent or unknown
  /// value, so a hand-typed location degrades instead of failing.
  static MetroMapMode fromName(String? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return time;
  }
}

String? metroStationIdForName(String name) {
  for (final station in metroMapStations) {
    if (station.name == name) return station.id;
  }
  return null;
}

class MetroMapStation {
  const MetroMapStation({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
  });
  final String id;
  final String name;
  final double x;
  final double y;
}

const metroMapStations = <MetroMapStation>[
  MetroMapStation(id: 'BL01', name: '頂埔', x: 111, y: 1630.42),
  MetroMapStation(id: 'BL02', name: '永寧', x: 167, y: 1574),
  MetroMapStation(id: 'BL03', name: '土城', x: 223, y: 1521),
  MetroMapStation(id: 'BL04', name: '海山', x: 223, y: 1462),
  MetroMapStation(id: 'BL05', name: '亞東醫院', x: 223, y: 1406),
  MetroMapStation(id: 'BL06', name: '府中', x: 223, y: 1350),
  MetroMapStation(id: 'BL07', name: '板橋', x: 223, y: 1294),
  MetroMapStation(id: 'BL08', name: '新埔', x: 237, y: 1224),
  MetroMapStation(id: 'BL09', name: '江子翠', x: 291, y: 1190),
  MetroMapStation(id: 'BL10', name: '龍山寺', x: 367, y: 1164.55),
  MetroMapStation(id: 'BL11_G12', name: '西門', x: 419, y: 1142),
  MetroMapStation(id: 'BL12_R10', name: '台北車站', x: 490, y: 1098),
  MetroMapStation(id: 'BL13', name: '善導寺', x: 546, y: 1098),
  MetroMapStation(id: 'BL14_O07', name: '忠孝新生', x: 602, y: 1098),
  MetroMapStation(id: 'BL15_BR10', name: '忠孝復興', x: 658, y: 1098),
  MetroMapStation(id: 'BL16', name: '忠孝敦化', x: 714, y: 1098),
  MetroMapStation(id: 'BL17', name: '國父紀念館', x: 770, y: 1098),
  MetroMapStation(id: 'BL18', name: '市政府', x: 826, y: 1098),
  MetroMapStation(id: 'BL19', name: '永春', x: 882, y: 1098),
  MetroMapStation(id: 'BL20', name: '後山埤', x: 916, y: 1064),
  MetroMapStation(id: 'BL21', name: '昆陽', x: 952, y: 1040),
  MetroMapStation(id: 'BL22', name: '南港', x: 994, y: 1040),
  MetroMapStation(id: 'BL23_BR24', name: '南港展覽館', x: 1050, y: 1040),
  MetroMapStation(id: 'BR01', name: '動物園', x: 938, y: 1382),
  MetroMapStation(id: 'BR02', name: '木柵', x: 882, y: 1382),
  MetroMapStation(id: 'BR03', name: '萬芳醫院', x: 826, y: 1382),
  MetroMapStation(id: 'BR04', name: '萬芳社區', x: 776, y: 1378),
  MetroMapStation(id: 'BR05', name: '辛亥', x: 770, y: 1322),
  MetroMapStation(id: 'BR06', name: '麟光', x: 770, y: 1271),
  MetroMapStation(id: 'BR07', name: '六張犁', x: 714, y: 1266),
  MetroMapStation(id: 'BR08', name: '科技大樓', x: 658, y: 1241),
  MetroMapStation(id: 'BR12', name: '中山國中', x: 658, y: 921),
  MetroMapStation(id: 'BR13', name: '松山機場', x: 658, y: 862),
  MetroMapStation(id: 'BR14', name: '大直', x: 658, y: 806),
  MetroMapStation(id: 'BR15', name: '劍南路', x: 714, y: 778),
  MetroMapStation(id: 'BR16', name: '西湖', x: 770, y: 778),
  MetroMapStation(id: 'BR17', name: '港墘', x: 826, y: 778),
  MetroMapStation(id: 'BR18', name: '文德', x: 882, y: 778),
  MetroMapStation(id: 'BR19', name: '內湖', x: 938, y: 778),
  MetroMapStation(id: 'BR20', name: '大湖公園', x: 988, y: 812),
  MetroMapStation(id: 'BR21', name: '葫洲', x: 1022, y: 862),
  MetroMapStation(id: 'BR22', name: '東湖', x: 1050, y: 918),
  MetroMapStation(id: 'BR23', name: '南港軟體園區', x: 1050, y: 984),
  MetroMapStation(id: 'G01', name: '新店', x: 686, y: 1686.35),
  MetroMapStation(id: 'G02', name: '新店區公所', x: 686, y: 1630),
  MetroMapStation(id: 'G03', name: '七張', x: 686, y: 1576.8),
  MetroMapStation(id: 'G03A', name: '小碧潭', x: 630, y: 1576),
  MetroMapStation(id: 'G05', name: '景美', x: 686, y: 1462),
  MetroMapStation(id: 'G06', name: '萬隆', x: 686, y: 1406),
  MetroMapStation(id: 'G07', name: '公館', x: 658, y: 1350),
  MetroMapStation(id: 'G08', name: '台電大樓', x: 602, y: 1294),
  MetroMapStation(id: 'G09_O05', name: '古亭', x: 546, y: 1238),
  MetroMapStation(id: 'G10_R08', name: '中正紀念堂', x: 490, y: 1182),
  MetroMapStation(id: 'G11', name: '小南門', x: 436.8, y: 1181.85),
  MetroMapStation(id: 'G13', name: '北門', x: 419, y: 1070),
  MetroMapStation(id: 'G14_R11', name: '中山', x: 490, y: 1014),
  MetroMapStation(id: 'G15_O08', name: '松江南京', x: 602, y: 1014),
  MetroMapStation(id: 'G16_BR11', name: '南京復興', x: 658, y: 1014),
  MetroMapStation(id: 'G17', name: '台北小巨蛋', x: 714, y: 1014),
  MetroMapStation(id: 'G18', name: '南京三民', x: 770, y: 1014),
  MetroMapStation(id: 'G19', name: '松山', x: 826, y: 1014),
  MetroMapStation(id: 'O01', name: '南勢角', x: 434, y: 1501),
  MetroMapStation(id: 'O03', name: '永安市場', x: 433, y: 1392),
  MetroMapStation(id: 'O04', name: '頂溪', x: 433, y: 1336),
  MetroMapStation(id: 'O09', name: '行天宮', x: 602, y: 961),
  MetroMapStation(id: 'O10', name: '中山國小', x: 575.85, y: 901.41),
  MetroMapStation(id: 'O11_R13', name: '民權西路', x: 490, y: 902),
  MetroMapStation(id: 'O12', name: '大橋頭', x: 434, y: 901.6),
  MetroMapStation(id: 'O13', name: '台北橋', x: 364, y: 924),
  MetroMapStation(id: 'O14', name: '菜寮', x: 322, y: 966),
  MetroMapStation(id: 'O15', name: '三重', x: 280, y: 1010.55),
  MetroMapStation(id: 'O16', name: '先嗇宮', x: 240.8, y: 1052.8),
  MetroMapStation(id: 'O17_Y18', name: '頭前庄', x: 202, y: 1097),
  MetroMapStation(id: 'O18', name: '新莊', x: 162, y: 1136),
  MetroMapStation(id: 'O19', name: '輔大', x: 120, y: 1178),
  MetroMapStation(id: 'O20', name: '丹鳳', x: 81, y: 1218),
  MetroMapStation(id: 'O21', name: '迴龍', x: 45, y: 1257),
  MetroMapStation(id: 'O50', name: '三重國小', x: 364, y: 880),
  MetroMapStation(id: 'O51', name: '徐匯中學', x: 322, y: 840),
  MetroMapStation(id: 'O52', name: '三和國中', x: 280, y: 801),
  MetroMapStation(id: 'O53', name: '三民高中', x: 241, y: 765),
  MetroMapStation(id: 'O54', name: '蘆洲', x: 202, y: 730),
  MetroMapStation(id: 'R02', name: '象山', x: 826, y: 1182),
  MetroMapStation(id: 'R03', name: '台北101/世貿', x: 770, y: 1182),
  MetroMapStation(id: 'R04', name: '信義安和', x: 714, y: 1182),
  MetroMapStation(id: 'R05_BR09', name: '大安', x: 658, y: 1182),
  MetroMapStation(id: 'R06', name: '大安森林公園', x: 616, y: 1182),
  MetroMapStation(id: 'R07_O06', name: '東門', x: 574, y: 1182),
  MetroMapStation(id: 'R09', name: '台大醫院', x: 490, y: 1140.35),
  MetroMapStation(id: 'R12', name: '雙連', x: 490, y: 958),
  MetroMapStation(id: 'R14', name: '圓山', x: 490, y: 846),
  MetroMapStation(id: 'R15', name: '劍潭', x: 490, y: 790),
  MetroMapStation(id: 'R16', name: '士林', x: 490, y: 734),
  MetroMapStation(id: 'R17', name: '芝山', x: 490, y: 678),
  MetroMapStation(id: 'R18', name: '明德', x: 490, y: 622),
  MetroMapStation(id: 'R19', name: '石牌', x: 448, y: 580),
  MetroMapStation(id: 'R20', name: '唭哩岸', x: 406, y: 538),
  MetroMapStation(id: 'R21', name: '奇岩', x: 367, y: 496),
  MetroMapStation(id: 'R22', name: '北投', x: 322, y: 454),
  MetroMapStation(id: 'R22A', name: '新北投', x: 361, y: 426),
  MetroMapStation(id: 'R23', name: '復興崗', x: 266, y: 454),
  MetroMapStation(id: 'R24', name: '忠義', x: 210, y: 454),
  MetroMapStation(id: 'R25', name: '關渡', x: 154, y: 426),
  MetroMapStation(id: 'R26', name: '竹圍', x: 154, y: 370),
  MetroMapStation(id: 'R27', name: '紅樹林', x: 154, y: 314),
  MetroMapStation(id: 'R28', name: '淡水', x: 126, y: 258),
  MetroMapStation(id: 'Y07_G04', name: '大坪林', x: 686, y: 1520.68),
  MetroMapStation(id: 'Y08', name: '十四張', x: 630, y: 1518),
  MetroMapStation(id: 'Y09', name: '秀朗橋', x: 574, y: 1515),
  MetroMapStation(id: 'Y10', name: '景平', x: 518, y: 1462),
  MetroMapStation(id: 'Y11_O02', name: '景安', x: 433, y: 1448),
  MetroMapStation(id: 'Y12', name: '中和', x: 377, y: 1448),
  MetroMapStation(id: 'Y13', name: '橋和', x: 321, y: 1448.35),
  MetroMapStation(id: 'Y14', name: '中原', x: 304, y: 1392),
  MetroMapStation(id: 'Y15', name: '板新', x: 279, y: 1336),
  MetroMapStation(id: 'Y16', name: '板橋', x: 259, y: 1280),
  MetroMapStation(id: 'Y17', name: '新埔民生', x: 202, y: 1195),
  MetroMapStation(id: 'Y19', name: '幸福', x: 202, y: 1041),
  MetroMapStation(id: 'Y20', name: '新北產業園區', x: 202, y: 982),
];

String? metroStationName(String code) => _stationNamesByCode[code];

final Map<String, String> _stationNamesByCode = {
  for (final station in metroMapStations)
    for (final code in station.id.split('_')) code: station.name,
};
