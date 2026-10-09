import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';

void main() {
  test('parses tagged metro/bus tokens', () {
    final r = parseAlertSources('metro:TRTC,bus:Taipei');
    expect(r.metro, ['TRTC']);
    expect(r.bus, ['Taipei']);
  });

  test('supports multiple sources per kind and trims whitespace', () {
    final r = parseAlertSources('metro:TRTC, metro:KRTC , bus:Taichung');
    expect(r.metro, ['TRTC', 'KRTC']);
    expect(r.bus, ['Taichung']);
  });

  test('drops malformed and unknown-kind tokens', () {
    final r = parseAlertSources('TRTC,rail:TRA,bus:,metro:TRTC,:x');
    expect(r.metro, ['TRTC']);
    expect(r.bus, isEmpty);
  });

  test('empty string yields no sources', () {
    final r = parseAlertSources('');
    expect(r.metro, isEmpty);
    expect(r.bus, isEmpty);
  });
}
