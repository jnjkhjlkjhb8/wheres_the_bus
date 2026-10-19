import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';

final _fix = Position(
  latitude: 25,
  longitude: 121,
  timestamp: DateTime.utc(2026, 10, 10),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class _LocationPlatform extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requestedPermission = LocationPermission.whileInUse;
  int requests = 0;
  int reads = 0;
  bool failLastKnown = false;
  LocationSettings? settings;

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return requestedPermission;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    settings = locationSettings;
    return _fix;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    reads++;
    if (failLastKnown) throw StateError('location unavailable');
    return _fix;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    settings = locationSettings;
    return Stream.value(_fix);
  }
}

void main() {
  late GeolocatorPlatform original;
  late _LocationPlatform platform;
  setUp(() {
    original = GeolocatorPlatform.instance;
    platform = _LocationPlatform();
    GeolocatorPlatform.instance = platform;
    LocationService.denial.value = null;
  });
  tearDown(() {
    GeolocatorPlatform.instance = original;
    LocationService.denial.value = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'a successful fix clears denial and uses bounded medium accuracy',
    () async {
      LocationService.denial.value = LocationDenial.permission;
      expect(await LocationService.instance.currentPosition(), same(_fix));
      expect(LocationService.denial.value, isNull);
      expect(platform.requests, 0);
      expect(platform.settings?.accuracy, LocationAccuracy.medium);
      expect(platform.settings?.timeLimit, const Duration(seconds: 10));
    },
  );

  test(
    'disabled service publishes a service denial before requesting permission',
    () async {
      platform.enabled = false;
      await expectLater(
        LocationService.instance.currentPosition(),
        throwsA(isA<LocationServiceDisabledException>()),
      );
      expect(LocationService.denial.value, LocationDenial.serviceDisabled);
      expect(platform.requests, 0);
    },
  );

  test('a denied permission is requested once and may become a fix', () async {
    platform.permission = LocationPermission.denied;
    expect(await LocationService.instance.currentPosition(), same(_fix));
    expect(platform.requests, 1);
    expect(LocationService.denial.value, isNull);
  });

  test('denied and permanently denied publish permission denial', () async {
    platform
      ..permission = LocationPermission.denied
      ..requestedPermission = LocationPermission.denied;
    await expectLater(
      LocationService.instance.currentPosition(),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(LocationService.denial.value, LocationDenial.permission);
    platform.permission = LocationPermission.deniedForever;
    await expectLater(
      LocationService.instance.currentPosition(),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(platform.requests, 1);
  });

  test(
    'last-known prefetch is consumed once and failures return no fix',
    () async {
      LocationService.instance
        ..prefetchLastKnown()
        ..prefetchLastKnown();
      expect(await LocationService.instance.lastKnownPosition(), same(_fix));
      expect(platform.reads, 1);
      expect(await LocationService.instance.lastKnownPosition(), same(_fix));
      expect(platform.reads, 2);
      platform.failLastKnown = true;
      expect(await LocationService.instance.lastKnownPosition(), isNull);
    },
  );

  test(
    'tracking and navigation retain their platform location settings',
    () async {
      expect(await LocationService.instance.positionStream().first, same(_fix));
      expect(platform.settings?.distanceFilter, 50);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        await LocationService.instance.navigationStream().first,
        same(_fix),
      );
      expect(platform.settings, isA<AndroidSettings>());
      expect(platform.settings?.distanceFilter, 5);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        await LocationService.instance.navigationStream().first,
        same(_fix),
      );
      expect(platform.settings, isA<AppleSettings>());
      expect(platform.settings?.distanceFilter, 5);
      debugDefaultTargetPlatformOverride = null;
    },
  );
  test('compass streams omit readings without a heading', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('hemanthraj/flutter_compass'),
          MockStreamHandler.inline(
            onListen: (_, events) {
              events
                ..success(null)
                ..success([90.0, 0.0, 1.0])
                ..endOfStream();
            },
          ),
        );
    expect(await LocationService.instance.compassStream().toList(), [90.0]);
  });
}
