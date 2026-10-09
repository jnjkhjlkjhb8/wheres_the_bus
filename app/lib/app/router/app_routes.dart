import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class AppRoutes {
  AppRoutes._();

  static const home = '/';
  static const settings = '/settings';
  static const settingsAppearance = '/settings/appearance';
  static const settingsFareType = '/settings/fare-type';
  static const settingsLanguage = '/settings/language';
  static const settingsWalkPace = '/settings/walk-pace';
  static const search = '/search';
  static const favorites = '/favorites';
  static const busStop = '/bus/stop';
  static const bikeStation = '/bike/station';
  static const rail = '/rail';
  static const metro = '/metro';
  static const go = '/go';
  static const feedback = '/feedback';

  static String feedbackLocation({String? from}) => from == null || from.isEmpty
      ? feedback
      : _location(feedback, {'from': from});

  /// Route pattern for the bus route detail screen; use [busRoute] to build a
  /// concrete location.
  static const busRoutePattern = '/bus/route/:subRouteUid';

  static String busRoute(String subRouteUid) =>
      '/bus/route/${Uri.encodeComponent(subRouteUid)}';

  /// [lat]/[lon] are an optional first-paint hint: when the caller already
  /// knows where the stop is (search results carry coordinates), the map opens
  /// on it without waiting for the station-group fetch.
  static String busStopLocation({
    required String stopName,
    String? stopId,
    String? city,
    double? lat,
    double? lon,
  }) => _location(
    busStop,
    {
      'name': stopName,
      'id': ?stopId,
      'city': ?city,
      'lat': ?lat?.toString(),
      'lon': ?lon?.toString(),
    },
  );

  /// [name]/[lat]/[lon] are optional first-paint hints — see
  /// [busStopLocation]. They seed the sheet title and camera target so neither
  /// waits on the static fetch.
  static String bikeStationLocation({
    required String stationUid,
    String? name,
    double? lat,
    double? lon,
  }) => _location(
    bikeStation,
    {
      'uid': stationUid,
      'name': ?name,
      'lat': ?lat?.toString(),
      'lon': ?lon?.toString(),
    },
  );

  static const nearStationPattern = '/near/:type/:id';

  static String nearStation({
    required NearStationType type,
    required String id,
    String? name,
    double? lat,
    double? lon,
    String? back,
  }) => _location(
    '/near/${type.name}/${Uri.encodeComponent(id)}',
    {
      'back': ?back,
      'name': ?name,
      'lat': ?lat?.toString(),
      'lon': ?lon?.toString(),
    },
  );

  static bool isHomeLocation(Uri uri) =>
      uri.path == home ||
      uri.path == railQueryPattern ||
      NearStationRouteArgs.fromUri(uri) != null;

  /// The rail query form as the home sheet's second layer — a sub-location of
  /// [home] on the same terms as [nearStationPattern].
  static const railQueryPattern = '/rail-query';

  static String railQuery({
    RailSystem system = RailSystem.tra,
    String? originName,
    String? originId,
  }) => _location(
    railQueryPattern,
    {
      'sys': system.name,
      'from': ?originName,
      'fromId': ?originId,
    },
  );

  static const metroStationPattern = '/metro/station/:id';

  /// [id] is a Taipei Metro (TDX) station code — the same id that keys ETA
  /// lookups and metro favorites, e.g. `BL15_BR10`.
  static String metroStation(String id, {MetroMapMode? mode}) => _location(
    '/metro/station/${Uri.encodeComponent(id)}',
    {'mode': ?mode?.name},
  );

  static String metroLocation({MetroMapMode? mode}) =>
      _location(metro, {'mode': ?mode?.name});

  static String railLocation({
    required RailSystem system,
    String? originName,
    String? originId,
    String? destName,
    String? destId,
    DateTime? date,
    bool isDeparture = true,
    bool submit = false,
  }) => _location(
    rail,
    {
      'sys': system.name,
      'from': ?originName,
      'fromId': ?originId,
      'to': ?destName,
      'toId': ?destId,
      'date': ?(date == null ? null : _minuteIso(date)),
      if (!isDeparture) 'dep': '0',
      if (submit) 'submit': '1',
    },
  );

  /// Route pattern for one train's stop list. Top-level and outside the shell:
  /// it is a full-screen page reached from the home sheet, the rail screen and
  /// search alike, so it must not stack a rail screen underneath.
  static const railTrainPattern = '/rail/train/:trainNo';

  /// [date] defaults to today at the screen, which is what every caller that
  /// has no particular day in mind wants.
  static String railTrain(
    String trainNo, {
    required RailSystem system,
    DateTime? date,
  }) => _location(
    '/rail/train/${Uri.encodeComponent(trainNo)}',
    {
      'sys': system.name,
      'date': ?(date == null ? null : _dateIso(date)),
    },
  );

  /// [query] pre-fills the search field; absent, the screen opens empty.
  static String searchLocation({String? query}) =>
      _location(search, {'q': ?query});

  /// Builds a location, dropping the query string entirely when nothing goes
  /// in it. `Uri` otherwise emits a bare `?`, which makes two spellings of the
  /// same place — and the one with the `?` is not what any route constant says.
  static String _location(String path, Map<String, String> params) => Uri(
    path: path,
    queryParameters: params.isEmpty ? null : params,
  ).toString();

  static String _dateIso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Minute precision: the rail query's time-of-day bounds the results, and
  /// seconds would only make two identical queries look different.
  static String _minuteIso(DateTime d) =>
      '${_dateIso(d)}T${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  /// The planner opened with its destination already filled in, so a station
  /// detail can hand off to it without the user re-typing where they are
  /// standing. The origin still resolves from GPS as usual.
  static String goToDestination({
    required String name,
    required double lat,
    required double lon,
  }) => _location(
    go,
    {
      'destName': name,
      'destLat': lat.toString(),
      'destLon': lon.toString(),
    },
  );
}

const appLinkScheme = 'wheresthebus';

/// Domain the app claims verified https links on.
const appLinkHost = 'rabbitsayhello.me';

const appLinkPathPrefix = '/app';

/// Turns an incoming deep-link location into a plain in-app location.
///
/// Returns null when [uri] is already one — the redirect then leaves it alone.
String? normalizeDeepLink(Uri uri) {
  if (!uri.hasScheme) return null;
  // A custom-scheme link can carry its first path segment as the authority,
  // which iOS preserves and Android drops; an https link's authority is the
  // domain, which goes away either way.
  var path = uri.scheme == appLinkScheme && uri.host.isNotEmpty
      ? '/${uri.host}${uri.path}'
      : uri.path;
  if (path == appLinkPathPrefix) {
    path = AppRoutes.home;
  } else if (path.startsWith('$appLinkPathPrefix/')) {
    path = path.substring(appLinkPathPrefix.length);
  }
  return Uri(
    path: path.isEmpty ? AppRoutes.home : path,
    queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
  ).toString();
}

/// Destination seed for [AppRoutes.go]. Absent or malformed parameters mean
/// the planner opens empty, exactly as it does from the nav bar.
class GoRouteArgs {
  const GoRouteArgs({required this.name, required this.lat, required this.lon});

  final String name;
  final double lat;
  final double lon;

  static GoRouteArgs? from(Map<String, String> query) {
    final name = query['destName'];
    final lat = double.tryParse(query['destLat'] ?? '');
    final lon = double.tryParse(query['destLon'] ?? '');
    if (name == null || name.isEmpty || lat == null || lon == null) return null;
    return GoRouteArgs(name: name, lat: lat, lon: lon);
  }
}

class BusStopRouteArgs {
  const BusStopRouteArgs({
    required this.stopName,
    this.stopId,
    this.city,
    this.lat,
    this.lon,
  });

  final String stopName;
  final String? stopId;
  final String? city;

  /// Optional first-paint coordinates from the caller; null means the screen
  /// waits for the station-group fetch as before.
  final double? lat;
  final double? lon;

  /// Returns null when neither [query] nor [extra] identify a stop; the
  /// router then renders [RouteErrorScreen] instead of crashing.
  static BusStopRouteArgs? from(Map<String, String> query, Object? extra) {
    final lat = double.tryParse(query['lat'] ?? '');
    final lon = double.tryParse(query['lon'] ?? '');
    final name = query['name'];
    if (name != null && name.isNotEmpty) {
      return BusStopRouteArgs(
        stopName: name,
        stopId: query['id'],
        city: query['city'],
        lat: lat,
        lon: lon,
      );
    }
    if (extra is Map) {
      final cachedName = extra['stopName'];
      final cachedId = extra['stopId'];
      final cachedCity = extra['city'];
      if (cachedName is String && cachedName.isNotEmpty) {
        return BusStopRouteArgs(
          stopName: cachedName,
          stopId: cachedId is String ? cachedId : null,
          city: cachedCity is String ? cachedCity : null,
          lat: lat,
          lon: lon,
        );
      }
    }
    return null;
  }
}

/// Parameters of the `/bike/station` route, resolved URL-first (see
/// [BusStopRouteArgs] for the query-vs-extra policy).
class BikeStationRouteArgs {
  const BikeStationRouteArgs({
    required this.stationUid,
    this.name,
    this.lat,
    this.lon,
  });

  final String stationUid;

  /// Optional first-paint hints from the caller; null means the screen waits
  /// for the static fetch as before.
  final String? name;
  final double? lat;
  final double? lon;

  static BikeStationRouteArgs? from(Map<String, String> query, Object? extra) {
    final name = query['name'];
    final lat = double.tryParse(query['lat'] ?? '');
    final lon = double.tryParse(query['lon'] ?? '');
    final uid = query['uid'];
    if (uid != null && uid.isNotEmpty) {
      return BikeStationRouteArgs(
        stationUid: uid,
        name: name,
        lat: lat,
        lon: lon,
      );
    }
    if (extra is Map) {
      final cached = extra['stationUid'];
      if (cached is String && cached.isNotEmpty) {
        return BikeStationRouteArgs(
          stationUid: cached,
          name: name,
          lat: lat,
          lon: lon,
        );
      }
    }
    return null;
  }
}

class NearStationRouteArgs {
  const NearStationRouteArgs({
    required this.type,
    required this.id,
    this.name,
    this.lat,
    this.lon,
    this.back,
  });

  final NearStationType type;
  final String id;
  final String? name;
  final double? lat;
  final double? lon;

  /// Where closing the sheet goes, or null for the bare map — see
  /// [AppRoutes.nearStation].
  final String? back;

  static NearStationRouteArgs? fromUri(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length != 3 || segments.first != 'near') return null;
    final id = segments[2];
    if (id.isEmpty) return null;
    for (final type in NearStationType.values) {
      if (type.name != segments[1]) continue;
      final query = uri.queryParameters;
      return NearStationRouteArgs(
        type: type,
        id: id,
        name: query['name'],
        lat: double.tryParse(query['lat'] ?? ''),
        lon: double.tryParse(query['lon'] ?? ''),
        back: query['back'],
      );
    }
    return null;
  }
}

/// Parameters of `/metro` and `/metro/station/:id`.
class MetroRouteArgs {
  const MetroRouteArgs({required this.mode, this.stationId});

  /// Nothing here can fail the route: an unreadable `mode` falls back to the
  /// map's default, and an absent station id simply means the bare map.
  factory MetroRouteArgs.from(
    Map<String, String> path,
    Map<String, String> query,
  ) {
    final id = path['id'];
    return MetroRouteArgs(
      stationId: id == null || id.isEmpty ? null : id,
      mode: MetroMapMode.fromName(query['mode']),
    );
  }

  /// TDX station code to pre-select, or null for the bare line map.
  final String? stationId;
  final MetroMapMode mode;
}

class RailRouteArgs {
  const RailRouteArgs({
    required this.system,
    required this.originName,
    required this.originId,
    required this.destName,
    required this.destId,
    required this.date,
    required this.isDeparture,
    required this.submit,
  });

  factory RailRouteArgs.from(Map<String, String> query) => RailRouteArgs(
    system: railSystemFromName(query['sys']),
    originName: query['from'] ?? '',
    originId: query['fromId'] ?? '',
    destName: query['to'] ?? '',
    destId: query['toId'] ?? '',
    date: DateTime.tryParse(query['date'] ?? ''),
    // Departure is the common query, so only its opposite is spelled out.
    isDeparture: query['dep'] != '0',
    submit: query['submit'] == '1',
  );

  final RailSystem system;
  final String originName;
  final String originId;
  final String destName;
  final String destId;

  /// Carries the time of day as well as the day: with [isDeparture] it bounds
  /// the results (depart at/after vs arrive at/before). Null means "now",
  /// resolved at the screen so a restored location is not stuck in the past.
  final DateTime? date;
  final bool isDeparture;
  final bool submit;
}

/// Parameters of `/rail/train/:trainNo`.
class RailTrainRouteArgs {
  const RailTrainRouteArgs({
    required this.trainNo,
    required this.system,
    this.date,
  });

  final String trainNo;
  final RailSystem system;

  /// Null means today, resolved at the screen.
  final DateTime? date;

  /// Returns null without a train number — the one parameter the screen
  /// cannot invent.
  static RailTrainRouteArgs? from(
    Map<String, String> path,
    Map<String, String> query,
  ) {
    final trainNo = path['trainNo'];
    if (trainNo == null || trainNo.isEmpty) return null;
    return RailTrainRouteArgs(
      trainNo: trainNo,
      system: railSystemFromName(query['sys']),
      date: DateTime.tryParse(query['date'] ?? ''),
    );
  }
}

/// Parameters of `/rail-query`, the rail form in the home sheet.
class RailQueryRouteArgs {
  const RailQueryRouteArgs({
    required this.system,
    this.originName,
    this.originId,
  });

  factory RailQueryRouteArgs.from(Map<String, String> query) =>
      RailQueryRouteArgs(
        system: railSystemFromName(query['sys']),
        originName: query['from'],
        originId: query['fromId'],
      );

  final RailSystem system;
  final String? originName;
  final String? originId;
}

/// Falls back to [RailSystem.tra] for an absent or unknown value: TRA is the
/// larger network, and a location that names no system is a caller that has
/// no opinion rather than one asking for high speed rail.
RailSystem railSystemFromName(String? name) {
  for (final system in RailSystem.values) {
    if (system.name == name) return system;
  }
  return RailSystem.tra;
}

/// Typed destination for unmatched locations and malformed route parameters,
/// so a bad deep link degrades to a recoverable page instead of a crash.
class RouteErrorScreen extends StatelessWidget {
  const RouteErrorScreen({required this.uri, super.key});

  /// The location that failed to resolve, shown for diagnosis.
  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppI18n.of(context).routeNotFound),
          const SizedBox(height: AppTheme.space8),
          Text('$uri', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppTheme.space16),
          TextButton(
            onPressed: () => GoRouter.of(context).go(AppRoutes.home),
            child: Text(AppI18n.of(context).routeGoHome),
          ),
        ],
      ),
    ),
  );
}
