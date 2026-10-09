import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/alert_decoder.dart';
import 'package:wheres_the_bus/data/generated/alert.pb.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';

void main() {
  const decoder = AlertDecoder.instance;

  test('carries scope, title, level and time through from the wire', () {
    final alerts = decoder.decode(
      Alert_Msg(
        items: [
          Alert_Item(
            id: 'hash',
            routeType: 'mrt',
            routeKeys: ['O', 'Y'],
            title: '中和新蘆線延誤',
            body: '因號誌故障,班距拉長',
            level: 'red',
            timeUnix: Int64(1768177800),
          ),
        ],
      ),
      source: const AlertSource(AlertSourceKind.metro, 'TRTC'),
    );

    expect(alerts, hasLength(1));
    final alert = alerts.single;
    expect(alert.title, '中和新蘆線延誤');
    expect(alert.message, '因號誌故障,班距拉長');
    expect(alert.level, AlertSeverity.red);
    expect(alert.routeType, 'mrt');
    expect(alert.routeKeys, ['O', 'Y']);
    expect(alert.source, const AlertSource(AlertSourceKind.metro, 'TRTC'));
    expect(alert.time, DateTime.fromMillisecondsSinceEpoch(1768177800 * 1000));
  });

  test('one message decodes every alert it carries', () {
    final alerts = decoder.decode(
      Alert_Msg(
        items: [
          Alert_Item(body: 'a', level: 'yellow'),
          Alert_Item(body: 'b', level: 'red'),
        ],
      ),
    );
    expect(alerts.map((a) => a.message), ['a', 'b']);
  });

  test('absent enrichment degrades to null rather than empty strings', () {
    final alert = decoder
        .decode(Alert_Msg(items: [Alert_Item(body: 'x')]))
        .single;
    expect(alert.title, isNull);
    expect(alert.time, isNull);
    expect(alert.source, isNull);
    expect(alert.routeKeys, isEmpty);
    // An unset level reads as advisory, never as "resolved".
    expect(alert.level, AlertSeverity.yellow);
  });

  test('an empty message decodes to no alerts, which clears the source', () {
    expect(decoder.decode(Alert_Msg()), isEmpty);
  });

  group('scope matching', () {
    test('an alert naming no route is system-wide and always matches', () {
      final alert = decoder
          .decode(
            Alert_Msg(
              items: [Alert_Item(routeType: 'tra', body: 'x')],
            ),
          )
          .single;
      expect(alert.matchesScope(const {}), isTrue);
      expect(alert.matchesScope(const {'bus:R1'}), isTrue);
    });

    test('a scoped alert matches only its own type and key', () {
      final alert = decoder
          .decode(
            Alert_Msg(
              items: [
                Alert_Item(routeType: 'tra', routeKeys: ['123'], body: 'x'),
              ],
            ),
          )
          .single;
      expect(alert.matchesScope(const {'tra:123'}), isTrue);
      // A bus route that happens to share the number must not match.
      expect(alert.matchesScope(const {'bus:123'}), isFalse);
      expect(alert.matchesScope(const {'tra:456'}), isFalse);
      expect(alert.matchesScope(const {}), isFalse);
    });
  });
}
