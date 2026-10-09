import 'package:wheres_the_bus/data/generated/alert.pb.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';

/// Proto → domain for alerts. The MQTT subscriber normalizes TDX's three
/// payload shapes at ingest, so nothing here parses or guesses a field name:
/// this is only the seam that keeps generated types out of `features/`.
class AlertDecoder {
  const AlertDecoder._();
  static const AlertDecoder instance = AlertDecoder._();

  List<AlertViewModel> decode(Alert_Msg msg, {AlertSource? source}) =>
      msg.items.map((item) => _item(item, source)).toList();

  AlertViewModel _item(Alert_Item item, AlertSource? source) => AlertViewModel(
    message: item.body,
    level: _level(item.level),
    routeType: item.routeType,
    routeKeys: List.unmodifiable(item.routeKeys),
    title: item.title.isEmpty ? null : item.title,
    time: item.timeUnix == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(item.timeUnix.toInt() * 1000),
    source: source,
    department: item.department.isEmpty ? null : item.department,
  );

  AlertSeverity _level(String level) => switch (level) {
    'red' => AlertSeverity.red,
    'green' => AlertSeverity.green,
    _ => AlertSeverity.yellow,
  };
}
