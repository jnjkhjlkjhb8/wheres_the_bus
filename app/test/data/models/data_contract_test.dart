import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

import '../../support/helpers/i18n.dart';

BusStopEtaViewModel eta(int seconds, int status) => BusStopEtaViewModel(
  stopUid: 'stop',
  direction: 0,
  sequence: 1,
  estimateSeconds: seconds,
  nextBusTime: '',
  stopStatus: status,
  vehiclePlates: const [],
);

void main() {
  test('coming-soon eligibility includes the boundary rank only', () {
    ArrivalDisplay display(int rank) => ArrivalDisplay(
      label: '307',
      destination: 'A',
      status: EtaStatus.arriving(),
      rank: rank,
    );
    expect(display(0).isComingSoon, isTrue);
    expect(display(3).isComingSoon, isTrue);
    expect(display(4).isComingSoon, isFalse);
  });

  test('feedback diagnostics omit unavailable fields in disclosure order', () {
    const diagnostics = FeedbackDiagnostics(
      appVersion: '1',
      platform: 'ios',
      osVersion: '18',
      screen: '/bus',
      locale: 'zh',
    );
    expect(diagnostics.summary, ['1', 'ios', '18', 'zh', '/bus']);
    expect(const FeedbackDiagnostics().summary, isEmpty);
    expect(
      diagnostics,
      const FeedbackDiagnostics(
        appVersion: '1',
        platform: 'ios',
        osVersion: '18',
        screen: '/bus',
        locale: 'zh',
      ),
    );
    for (final category in FeedbackCategory.values) {
      expect(category.labelOf(zhStrings), isNotEmpty);
      expect(category.hintOf(zhStrings), isNotEmpty);
    }
    final created = DateTime(2026, 10, 10);
    final receipt = FeedbackReceipt(threadId: 'abcd-1234', createdAt: created);
    expect(receipt.reference, 'ABCD');
    expect(receipt, FeedbackReceipt(threadId: 'abcd-1234', createdAt: created));
  });

  test(
    'metro tracking defaults are terminal and station boundaries are safe',
    () {
      final empty = MrtTrackSession.fromJson(const {});
      expect(empty.status, MrtTrackStatus.cancelled);
      expect(empty.status.isTerminal, isTrue);
      expect(empty.boardStationId, '');
      expect(empty.targetStationName, '');
      expect(empty.line, '');
      final json = <String, dynamic>{
        'trackId': 'id',
        'tripId': 'trip',
        'carId': 'car',
        'pathStationIds': ['BL01', 'BL02'],
        'pathStationNames': ['頂埔', '永寧'],
        'targetIndex': 1,
        'currentIndex': 0,
        'remainingStops': 1,
        'nextStationId': 'BL02',
        'nextStationName': '永寧',
        'progress': 0.5,
        'status': 'tracking',
        'leadStops': 2,
        'system': 'TRTC',
      };
      final session = MrtTrackSession.fromJson(json);
      expect(session.boardStationId, 'BL01');
      expect(session.targetStationName, '永寧');
      expect(session.line, 'BL');
      expect(session.toJson(), json);
      expect(MrtTrackSession.fromJson(session.toJson()), session);
      expect(
        MrtTrackSession.fromJson({
          ...json,
          'targetIndex': -1,
        }).targetStationName,
        '',
      );
      expect(
        MrtTrackSession.fromJson({...json, 'targetIndex': 2}).targetStationName,
        '',
      );
      final statuses = <String, MrtTrackStatus>{
        'tracking': MrtTrackStatus.tracking,
        'lead_fired': MrtTrackStatus.leadFired,
        'arrived': MrtTrackStatus.arrived,
        'lost': MrtTrackStatus.lost,
        'stale': MrtTrackStatus.stale,
        'cancelled': MrtTrackStatus.cancelled,
        'unknown': MrtTrackStatus.cancelled,
      };
      for (final entry in statuses.entries) {
        expect(MrtTrackStatus.fromWire(entry.key), entry.value);
        expect(
          entry.value.isTerminal,
          !['tracking', 'lead_fired'].contains(entry.key),
        );
      }
      expect(mrtLineOfStation('BR01'), 'BR');
      expect(mrtLineOfStation('123'), '');
    },
  );

  test(
    'planner options retain omitted fields and can clear a transfer ceiling',
    () {
      const options = PlanOptions(
        gc: 1,
        top: 2,
        transitModes: [3],
        transferMin: 4,
        transferMax: 5,
        firstMileMode: 6,
        firstMileTime: 7,
        lastMileMode: 8,
        lastMileTime: 9,
        maxTransfers: 10,
        avoidReservation: true,
        carryBike: true,
        wheelchair: true,
        walkSpeedCmPerSec: 80,
      );
      expect(options.copyWith(), options);
      expect(options.copyWith(clearMaxTransfers: true).maxTransfers, isNull);
      final changed = options.copyWith(
        gc: 2,
        top: 3,
        transitModes: [4],
        transferMin: 5,
        transferMax: 6,
        firstMileMode: 7,
        firstMileTime: 8,
        lastMileMode: 9,
        lastMileTime: 10,
        maxTransfers: 11,
        avoidReservation: false,
        carryBike: false,
        wheelchair: false,
        walkSpeedCmPerSec: 90,
      );
      expect(
        changed,
        const PlanOptions(
          gc: 2,
          top: 3,
          transitModes: [4],
          transferMin: 5,
          transferMax: 6,
          firstMileMode: 7,
          firstMileTime: 8,
          lastMileMode: 9,
          maxTransfers: 11,
          walkSpeedCmPerSec: 90,
        ),
      );
    },
  );

  test(
    'rail quotes select the operator and retain immutable value equality',
    () {
      const empty = RailFareQuote.thsr(fares: []);
      expect(empty.isEmpty, isTrue);
      expect(empty.resolve(FareType.full), isNull);
      const thsr = RailFareQuote.thsr(
        fares: [ThsrFare(fareClass: 1, price: 100)],
      );
      expect(thsr.isEmpty, isFalse);
      expect(thsr.resolve(FareType.full), (price: 100, matched: FareType.full));
      expect(
        thsr,
        const RailFareQuote.thsr(
          fares: [ThsrFare(fareClass: 1, price: 100)],
        ),
      );
      const tra = RailFareQuote.tra(
        fares: [TraFare(ticketType: '成自', price: 50)],
        trainType: '',
      );
      expect(tra.isEmpty, isFalse);
      expect(tra.resolve(FareType.full), (price: 50, matched: FareType.full));
      expect(
        tra,
        const RailFareQuote.tra(
          fares: [TraFare(ticketType: '成自', price: 50)],
          trainType: '',
        ),
      );
      const stop = TimelineStop(uid: 'id', name: 'name', etaMinutes: 2);
      expect(stop, const TimelineStop(uid: 'id', name: 'name', etaMinutes: 2));
      expect(
        stop,
        isNot(const TimelineStop(uid: 'id', name: 'name', etaMinutes: 3)),
      );
    },
  );

  test('arrival status keeps a missing estimate distinct from arrival', () {
    expect(eta(0, 0).status, BusArrivalStatus.arriving);
    expect(eta(0, 1).status, BusArrivalStatus.unknown);
    expect(eta(-1, 0).status, BusArrivalStatus.unknown);
    expect(eta(1, 0).status, BusArrivalStatus.approaching);
    expect(eta(59, 0).status, BusArrivalStatus.approaching);
    expect(eta(60, 0).status, BusArrivalStatus.minutes);
  });

  test('only ended service codes suppress ongoing service', () {
    for (final status in [-1, 0, 1, 2, 5]) {
      expect(busStopServiceEnded(status), isFalse);
    }
    expect(busStopServiceEnded(3), isTrue);
    expect(busStopServiceEnded(4), isTrue);
  });

  test('scheduled clocks and missing estimates are not live labels', () {
    expect(busStopLabelIsLive(estimateSeconds: 90, stopStatus: 1), isFalse);
    expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 1), isFalse);
    expect(busStopLabelIsLive(estimateSeconds: 1, stopStatus: 2), isTrue);
    expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 0), isTrue);
    expect(busStopLabelIsLive(estimateSeconds: 0, stopStatus: 2), isFalse);
    expect(busStopLabelIsLive(estimateSeconds: -1, stopStatus: 2), isFalse);
  });

  test(
    'scheduled display accepts date-only clocks and rejects invalid dates',
    () {
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: '2026-10-10',
        ),
        '00:00',
      );
      expect(
        busStopDisplayLabel(
          i18n: zhStrings,
          estimateSeconds: 0,
          stopStatus: 1,
          nextBusTime: 'invalid',
        ),
        zhStrings.etaNotDeparted,
      );
    },
  );

  test('metro map mode resolves known values and defaults unknown values', () {
    expect(MetroMapMode.fromName('time'), MetroMapMode.time);
    expect(MetroMapMode.fromName('fare'), MetroMapMode.fare);
    expect(MetroMapMode.fromName('FARE'), MetroMapMode.time);
    expect(MetroMapMode.fromName(null), MetroMapMode.time);
    expect(metroStationIdForName('頂埔'), 'BL01');
    expect(metroStationIdForName('台北車站'), 'BL12_R10');
    expect(metroStationIdForName('missing'), isNull);
  });

  test(
    'announcement tone remains informational even with critical severity',
    () {
      for (final severity in AlertSeverity.values) {
        final announcement = AlertViewModel(
          message: 'notice',
          level: severity,
          source: const AlertSource(AlertSourceKind.appNotice),
        );
        expect(announcement.kind, NoticeKind.announcement);
        expect(announcement.tone, NoticeTone.info);
        expect(announcement.ongoing, isFalse);
      }
      const critical = AlertViewModel(message: 'red', level: AlertSeverity.red);
      const caution = AlertViewModel(
        message: 'yellow',
        level: AlertSeverity.yellow,
      );
      expect(critical.kind, NoticeKind.disruption);
      expect(critical.tone, NoticeTone.critical);
      expect(caution.tone, NoticeTone.caution);
      expect(critical.ongoing, isTrue);
    },
  );
}
