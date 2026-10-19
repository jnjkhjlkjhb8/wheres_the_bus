import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_event.dart';

class _Repo extends MrtRepository {
  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) =>
      const Stream.empty();

  @override
  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async => const [
    MetroScheduleEntry(
      line: 'R',
      destination: 'ZZ-unknown',
      firstTime: '24:05',
      lastTime: '25:10',
    ),
  ];
}

void main() {
  test('loading a station publishes its normalized schedule', () async {
    final bloc = MetroEtaBloc(repository: _Repo());
    addTearDown(bloc.close);
    bloc.add(const LoadMetroEta('TRTC', 'R10'));
    final state = await bloc.stream.firstWhere((s) => s.schedule.isNotEmpty);
    expect(state.schedule.single.line, 'R');
    expect(state.schedule.single.destination, 'ZZ-unknown');
    expect(state.schedule.single.firstTime, '00:05');
    expect(state.schedule.single.lastTime, '01:10');
  });

  test('entries differing in any key field are all kept', () {
    MetroScheduleEntry e(String l, String d, String f, String t) =>
        MetroScheduleEntry(line: l, destination: d, firstTime: f, lastTime: t);
    final out = metroScheduleFrom([
      e('R', 'A', '06:00', '23:00'),
      e('R', 'A', '06:00', '23:00'),
      e('R', 'B', '06:00', '23:00'),
      e('R', 'A', '06:01', '23:00'),
      e('R', 'A', '06:00', '23:01'),
      e('G', 'A', '06:00', '23:00'),
    ]);
    expect(out, hasLength(5));
  });

  test('hours below 24 pass through untouched, even unpadded', () {
    expect(normalizeServiceTime('8:05'), '8:05');
    expect(normalizeServiceTime('23:59'), '23:59');
    expect(normalizeServiceTime('24:00'), '00:00');
    expect(normalizeServiceTime('x:00'), 'x:00');
  });
}
