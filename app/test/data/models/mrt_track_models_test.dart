import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';

MrtTrackSession _session({
  String trackId = 'track-1',
  String tripId = 'trip-1',
  String carId = 'car-1',
  List<String> pathStationIds = const ['BL01', 'BL02'],
  List<String> pathStationNames = const ['頂埔', '永寧'],
  int targetIndex = 1,
  int currentIndex = 0,
  int remainingStops = 1,
  String nextStationId = 'BL02',
  String nextStationName = '永寧',
  double progress = 0.5,
  MrtTrackStatus status = MrtTrackStatus.tracking,
  int leadStops = 2,
  String system = 'TRTC',
}) => MrtTrackSession(
  trackId: trackId,
  tripId: tripId,
  carId: carId,
  pathStationIds: pathStationIds,
  pathStationNames: pathStationNames,
  targetIndex: targetIndex,
  currentIndex: currentIndex,
  remainingStops: remainingStops,
  nextStationId: nextStationId,
  nextStationName: nextStationName,
  progress: progress,
  status: status,
  leadStops: leadStops,
  system: system,
);

void main() {
  test(
    'station line prefixes preserve leading ASCII letters and their case',
    () {
      final cases = <String, String>{
        'BL12': 'BL',
        'br01': 'br',
        'Rbl03': 'Rbl',
        'A1': 'A',
        'z9': 'z',
        'BL12R': 'BL',
        '123BL': '',
        '-BL12': '',
        '': '',
      };
      for (final entry in cases.entries) {
        expect(mrtLineOfStation(entry.key), entry.value, reason: entry.key);
      }
    },
  );

  test('the first named station is a valid tracking target', () {
    expect(_session(targetIndex: 0).targetStationName, '頂埔');
    expect(
      _session(pathStationNames: ['頂埔'], targetIndex: 0).targetStationName,
      '頂埔',
    );
    expect(
      MrtTrackSession.fromJson(const {
        'pathStationNames': ['起點', '終點'],
      }).targetStationName,
      '起點',
    );
  });

  test('an omitted tracking payload saves all offline defaults explicitly', () {
    final session = MrtTrackSession.fromJson(const {});
    expect(session.toJson(), {
      'trackId': '',
      'tripId': '',
      'carId': '',
      'pathStationIds': <String>[],
      'pathStationNames': <String>[],
      'targetIndex': 0,
      'currentIndex': 0,
      'remainingStops': 0,
      'nextStationId': '',
      'nextStationName': '',
      'progress': 0.0,
      'status': 'cancelled',
      'leadStops': 1,
      'system': 'TRTC',
    });
  });

  test('independent equal tracking sessions share a value and hash', () {
    final first = _session(
      pathStationIds: ['BL01', 'BL02'],
      pathStationNames: ['頂埔', '永寧'],
    );
    final second = _session(
      pathStationIds: ['BL01', 'BL02'],
      pathStationNames: ['頂埔', '永寧'],
    );
    expect(identical(first, second), isFalse);
    expect(identical(first.pathStationIds, second.pathStationIds), isFalse);
    expect(identical(first.pathStationNames, second.pathStationNames), isFalse);
    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect({first, second}, hasLength(1));
  });

  test('all session fields and ordered path content distinguish tracks', () {
    final original = _session();
    final changed = <MrtTrackSession>[
      _session(trackId: 'track-2'),
      _session(tripId: 'trip-2'),
      _session(carId: 'car-2'),
      _session(pathStationIds: ['BL01', 'BL03']),
      _session(pathStationNames: ['頂埔', '板橋']),
      _session(targetIndex: 0),
      _session(currentIndex: 1),
      _session(remainingStops: 2),
      _session(nextStationId: 'BL03'),
      _session(nextStationName: '板橋'),
      _session(progress: 0.75),
      _session(status: MrtTrackStatus.leadFired),
      _session(leadStops: 3),
      _session(system: 'KRTC'),
      _session(pathStationIds: ['BL02', 'BL01']),
      _session(pathStationNames: ['永寧', '頂埔']),
      _session(pathStationIds: ['BL01']),
      _session(pathStationNames: ['頂埔']),
    ];
    for (final session in changed) {
      expect(session, isNot(original));
    }
    expect({original, ...changed}, hasLength(19));
  });
}
