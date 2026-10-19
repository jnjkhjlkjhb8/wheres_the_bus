import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';

void main() {
  const eta = BusStopEtaViewModel(
    stopUid: 's',
    direction: 0,
    sequence: 1,
    estimateSeconds: 60,
    nextBusTime: '',
    stopStatus: 0,
    vehiclePlates: [],
  );
  const fare = BusFareInfo(
    pricingType: 1,
    isFreeBus: false,
    sectionFaresJson: [],
    stageFaresJson: [],
    odFaresJson: [],
  );

  test('events without payload carry no props', () {
    expect(const BusRouteStarted().props, isEmpty);
    expect(const BusRouteStreamRecovered().props, isEmpty);
  });

  test('BusRouteDirectionToggled compares the direction', () {
    expect(
      const BusRouteDirectionToggled(1),
      const BusRouteDirectionToggled(1),
    );
    expect(
      const BusRouteDirectionToggled(1),
      isNot(const BusRouteDirectionToggled(0)),
    );
  });

  test('BusRouteEtaUpdated compares the eta map', () {
    expect(
      const BusRouteEtaUpdated({'s': eta}),
      const BusRouteEtaUpdated({'s': eta}),
    );
    expect(
      const BusRouteEtaUpdated({'s': eta}),
      isNot(const BusRouteEtaUpdated({})),
    );
  });

  test('BusRouteDetailsUpdated compares daily and fare', () {
    const daily = BusDailyTimetable(directions: {0: []});
    expect(
      const BusRouteDetailsUpdated(daily: daily, fare: fare),
      const BusRouteDetailsUpdated(daily: daily, fare: fare),
    );
    expect(
      const BusRouteDetailsUpdated(daily: daily, fare: fare),
      isNot(const BusRouteDetailsUpdated(fare: fare)),
    );
    expect(
      const BusRouteDetailsUpdated(daily: daily, fare: fare),
      isNot(const BusRouteDetailsUpdated(daily: daily)),
    );
  });

  test('BusRoutePinnedReminderArmed compares stop, plate and event', () {
    const armed = BusRoutePinnedReminderArmed(
      stopUid: 's',
      plate: 'p',
      event: AlightEvent.lead,
    );
    expect(
      armed,
      const BusRoutePinnedReminderArmed(
        stopUid: 's',
        plate: 'p',
        event: AlightEvent.lead,
      ),
    );
    expect(
      armed,
      isNot(
        const BusRoutePinnedReminderArmed(
          stopUid: 'x',
          plate: 'p',
          event: AlightEvent.lead,
        ),
      ),
    );
    expect(
      armed,
      isNot(
        const BusRoutePinnedReminderArmed(
          stopUid: 's',
          plate: 'x',
          event: AlightEvent.lead,
        ),
      ),
    );
    expect(
      armed,
      isNot(
        const BusRoutePinnedReminderArmed(
          stopUid: 's',
          plate: 'p',
          event: AlightEvent.alight,
        ),
      ),
    );
  });

  test('BusRouteStreamFailed compares the error', () {
    expect(
      const BusRouteStreamFailed(OfflineError()),
      const BusRouteStreamFailed(OfflineError()),
    );
    expect(
      const BusRouteStreamFailed(OfflineError()),
      isNot(const BusRouteStreamFailed(TimeoutError())),
    );
  });
}
