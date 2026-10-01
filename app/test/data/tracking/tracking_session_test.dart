import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/data/tracking/tracking_session.dart';

void main() {
  BusStopModel stop(int seq, String uid, String name) => BusStopModel(
    stopUid: uid,
    stopName: name,
    sequence: seq,
    lat: 25,
    lon: 121.5,
  );

  final route = BusRouteViewModel(
    subRouteUid: 'TPE1234',
    routeName: '307',
    subRouteName: '307',
    departureStopName: '撫遠街',
    destinationStopName: '板橋',
    city: 'Taipei',
    headsignGo: '板橋',
    headsignReturn: '撫遠街',
    stopsGo: [stop(1, 'S1', '第一站'), stop(2, 'S2', '第二站'), stop(3, 'S3', '終點')],
  );

  JourneySessionState tracking(JourneyLeg leg) => JourneySessionState(
    phase: JourneyPhase.waiting,
    trackOnly: true,
    legs: [leg],
  );

  group('busTrackingLabel', () {
    test('appends the headsign only when the feed publishes one', () {
      expect(busTrackingLabel(routeName: '307', headsign: '板橋'), '307 往板橋');
      expect(busTrackingLabel(routeName: '307', headsign: ''), '307');
    });
  });

  group('busTrackingLeg', () {
    test('names the alight stop the rider picked, not the terminus', () {
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: 0,
        targetIndex: 1,
        direction: 0,
      );
      expect(leg.kind, JourneyLegKind.bus);
      expect(leg.routeLabel, '307 往板橋');
      // Where the rider got on, and where they get off. The terminus is not
      // either of them.
      expect(leg.boardStop, '第一站');
      expect(leg.alightStop, '第二站');
      expect(leg.identity.departureStopKey, 'S2');
      expect(leg.identity.routeKey, 'TPE1234');
    });

    test('carries the hops from 上車站 to 下車站', () {
      // The card's progress bar divides by these, so they must span that
      // stretch and nothing else: one entry per stop after the 上車站.
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: 0,
        targetIndex: 2,
        direction: 0,
      );
      expect(leg.stopNames, ['第二站', '終點']);
      expect(leg.stopLocations, hasLength(2));
    });

    test('spans nothing when 上車站 and 下車站 are the same stop', () {
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: 2,
        targetIndex: 2,
        direction: 0,
      );
      expect(leg.stopNames, isEmpty);
      expect(leg.stopLocations, isEmpty);
    });

    test('falls back to the route start when no 上車站 was resolved', () {
      // -1 is what the caller passes when the screen never snapshotted the
      // stop the bus was heading for: the bar then spans the whole run to the
      // target rather than collapsing to zero hops and freezing.
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: -1,
        targetIndex: 2,
        direction: 0,
      );
      expect(leg.boardStop, '第一站');
      expect(leg.stopNames, ['第二站', '終點']);
    });

    test('takes the return headsign for direction 1', () {
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: 0,
        targetIndex: 0,
        direction: 1,
      );
      expect(leg.routeLabel, '307 往撫遠街');
      expect(leg.identity.direction, '1');
    });

    test('leaves the identity unsupported', () {
      // A trackOnly identity is not a bookable plan section.
      final leg = busTrackingLeg(
        route: route,
        stops: route.stopsGo,
        boardIndex: 0,
        targetIndex: 1,
        direction: 0,
      );
      expect(leg.identity.supported, isFalse);
    });
  });

  group('trackedBusStopUid', () {
    final leg = busTrackingLeg(
      route: route,
      stops: route.stopsGo,
      boardIndex: 0,
      targetIndex: 1,
      direction: 0,
    );

    test('returns the target stop for this route', () {
      expect(trackedBusStopUid(tracking(leg), 'TPE1234'), 'S2');
    });

    test('ignores another route running its own 追蹤', () {
      expect(trackedBusStopUid(tracking(leg), 'TPE9999'), isNull);
    });

    test('ignores a navigation session on the same route', () {
      // trackOnly false means the rider is being navigated, not watching a
      // stop, so this route's toggles must stay idle.
      final navigating = JourneySessionState(
        phase: JourneyPhase.waiting,
        legs: [leg],
      );
      expect(trackedBusStopUid(navigating, 'TPE1234'), isNull);
    });

    test('ignores a session that already left the waiting phase', () {
      final riding = JourneySessionState(
        phase: JourneyPhase.riding,
        trackOnly: true,
        legs: [leg],
      );
      expect(trackedBusStopUid(riding, 'TPE1234'), isNull);
    });

    test('is null for an idle session or an unknown route', () {
      expect(trackedBusStopUid(const JourneySessionState(), 'TPE1234'), isNull);
      expect(trackedBusStopUid(tracking(leg), null), isNull);
    });
  });

  group('isTrackingTrain', () {
    JourneyLeg railLeg({
      required String trainNo,
      required String date,
      bool isThsr = false,
    }) => JourneyLeg(
      kind: isThsr ? JourneyLegKind.thsr : JourneyLegKind.tra,
      routeLabel: '$trainNo 次',
      boardStop: '台北',
      alightStop: '台中',
      stopNames: const [],
      identity: PlanIdentity(
        routeType: isThsr ? 'thsr' : 'tra',
        routeKey: trainNo,
        direction: date,
        departureStopKey: '',
        arrivalStopKey: '',
        supported: false,
      ),
      leadingWalkMinutes: 0,
      scheduledDeparture: null,
      scheduledArrival: null,
      boardLocation: const PlanPoint(lat: 0, lng: 0),
      stopLocations: const [],
    );

    test('matches the same train on the same service date', () {
      final state = tracking(railLeg(trainNo: '152', date: '2026-08-02'));
      expect(
        isTrackingTrain(state, trainNo: '152', serviceDate: '2026-08-02'),
        isTrue,
      );
    });

    test('does not match the same train number on another day', () {
      // Train numbers repeat daily; without the date, tomorrow's 152 次 would
      // light up today's screen.
      final state = tracking(railLeg(trainNo: '152', date: '2026-08-02'));
      expect(
        isTrackingTrain(state, trainNo: '152', serviceDate: '2026-08-03'),
        isFalse,
      );
    });

    test('matches THSR legs too', () {
      final state = tracking(
        railLeg(trainNo: '0803', date: '2026-08-02', isThsr: true),
      );
      expect(
        isTrackingTrain(state, trainNo: '0803', serviceDate: '2026-08-02'),
        isTrue,
      );
    });

    test('does not mistake a bus 追蹤 for a train', () {
      final state = tracking(
        busTrackingLeg(
          route: route,
          stops: route.stopsGo,
          boardIndex: 0,
          targetIndex: 0,
          direction: 0,
        ),
      );
      expect(
        isTrackingTrain(state, trainNo: 'TPE1234', serviceDate: '0'),
        isFalse,
      );
    });
  });
}
