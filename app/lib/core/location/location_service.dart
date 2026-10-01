import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

/// Why the app currently has no fix. Published by [LocationService.denial] so
/// the resident notice rail can say so without every screen re-deriving it
/// from a caught exception.
enum LocationDenial { permission, serviceDisabled }

/// Wrapper around geolocator — handles permission and fallback.
class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  /// Current reason location is unavailable, or null once a fix succeeds.
  /// Written by [currentPosition] on every attempt, so it always reflects the
  /// last real answer from the OS rather than a stale first-launch guess.
  static final denial = ValueNotifier<LocationDenial?>(null);

  Future<Position> currentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      denial.value = LocationDenial.serviceDisabled;
      throw const LocationServiceDisabledException();
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        denial.value = LocationDenial.permission;
        throw const PermissionDeniedException('Location permission denied');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      denial.value = LocationDenial.permission;
      throw const PermissionDeniedException(
        'Location permission permanently denied',
      );
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 10),
      ),
    );
    denial.value = null;
    return position;
  }

  Future<Position?>? _prefetchedLastKnown;

  void prefetchLastKnown() {
    _prefetchedLastKnown ??= _readLastKnown();
  }

  Future<Position?> lastKnownPosition() {
    final prefetched = _prefetchedLastKnown;
    _prefetchedLastKnown = null;
    return prefetched ?? _readLastKnown();
  }

  Future<Position?> _readLastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } on Object {
      return null;
    }
  }

  /// Continuous position stream (low power).
  Stream<Position> positionStream() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 50,
    ),
  );

  Stream<Position> navigationStream() {
    late final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // AppleSettings.accuracy defaults to best; omitted here to satisfy the
      // analyzer while keeping full-accuracy foreground tracking.
      settings = AppleSettings(
        activityType: ActivityType.otherNavigation,
        // 5 m keeps the follow camera moving at walking pace; 25 m delivered a
        // fix only every ~20 s of walking, which read as "not following".
        distanceFilter: 5,
      );
    } else {
      settings = AndroidSettings(distanceFilter: 5);
    }
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  Stream<double> compassStream() {
    final events = FlutterCompass.events;
    if (events == null) return const Stream.empty();
    return events
        .map((event) => event.heading)
        .where((heading) => heading != null)
        .cast<double>();
  }
}
