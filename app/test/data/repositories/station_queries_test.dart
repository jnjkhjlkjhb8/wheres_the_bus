import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';

import '../../support/helpers/fake_local_db.dart';

void main() {
  group('MrtRepository local queries', () {
    test('schedule maps rows to schedule entries', () async {
      final repo = MrtRepository(
        localDb: FakeLocalDb({
          'TRTC': [
            {
              'lineid': 'BL',
              'destinationstaionid': 'BL01',
              'first_train_time': '06:00',
              'last_train_time': '00:00',
            },
          ],
        }),
      );
      final schedule = await repo.schedule('TRTC', 'BL12');
      expect(schedule, hasLength(1));
      expect(schedule.first.line, 'BL');
      expect(schedule.first.destination, 'BL01');
      expect(schedule.first.firstTime, '06:00');
      expect(schedule.first.lastTime, '00:00');
    });

    test(
      'schedule scopes by system and expands an interchange id into its '
      'component codes — mrt_schedule is keyed by single TDX codes, and a '
      'code is only unique within one operator',
      () async {
        final db = FakeLocalDb({});
        await MrtRepository(localDb: db).schedule('TRTC', 'BL12_R10');
        expect(db.calls.single.parameters, ['TRTC', 'BL12', 'R10']);
        expect(db.calls.single.sql, contains('system = ?'));
        expect(db.calls.single.sql, contains('station_id IN (?,?)'));
      },
    );

    test('journeyMatrix keys rows by destination station id', () async {
      final repo = MrtRepository(
        localDb: FakeLocalDb({
          'BL12': [
            {'to_station_id': 'BL01', 'fare_nt': 20},
            {'to_station_id': 'BL02', 'fare_nt': 25},
          ],
        }),
      );
      final matrix = await repo.journeyMatrix('BL12');
      expect(matrix.keys, containsAll(['BL01', 'BL02']));
      expect(matrix['BL02']?.fareNt, 25);
    });

    test('empty result yields empty schedule and matrix', () async {
      final repo = MrtRepository(localDb: FakeLocalDb({}));
      expect(await repo.schedule('TRTC', 'nope'), isEmpty);
      expect(await repo.journeyMatrix('nope'), isEmpty);
    });
  });
}
