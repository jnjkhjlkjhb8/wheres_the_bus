import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';

void main() {
  group('AppRoutes.busRoute', () {
    test('encodes the subRouteUid path segment', () {
      expect(AppRoutes.busRoute('TPE 307/a'), '/bus/route/TPE%20307%2Fa');
    });

    test('leaves plain ids untouched', () {
      expect(AppRoutes.busRoute('TPE10132'), '/bus/route/TPE10132');
    });
  });

  group('AppRoutes.busStopLocation', () {
    test('round-trips name, id, and city through the URI', () {
      final location = AppRoutes.busStopLocation(
        stopName: '台北車站',
        stopId: 'S18',
        city: 'Taipei',
      );
      final uri = Uri.parse(location);
      expect(uri.path, AppRoutes.busStop);
      expect(uri.queryParameters['name'], '台北車站');
      expect(uri.queryParameters['id'], 'S18');
      expect(uri.queryParameters['city'], 'Taipei');
    });

    test('omits absent optional parameters', () {
      final uri = Uri.parse(AppRoutes.busStopLocation(stopName: '南港'));
      expect(uri.queryParameters['name'], '南港');
      expect(uri.queryParameters.containsKey('id'), isFalse);
      expect(uri.queryParameters.containsKey('city'), isFalse);
      expect(uri.queryParameters.containsKey('lat'), isFalse);
      expect(uri.queryParameters.containsKey('lon'), isFalse);
    });

    test('carries the first-paint coordinates when supplied', () {
      final uri = Uri.parse(
        AppRoutes.busStopLocation(
          stopName: '南港',
          lat: 25.053,
          lon: 121.6067,
        ),
      );
      expect(uri.queryParameters['lat'], '25.053');
      expect(uri.queryParameters['lon'], '121.6067');
    });
  });

  group('AppRoutes.bikeStationLocation', () {
    test('carries the station uid as a query parameter', () {
      final uri = Uri.parse(
        AppRoutes.bikeStationLocation(stationUid: 'TPE0001'),
      );
      expect(uri.path, AppRoutes.bikeStation);
      expect(uri.queryParameters['uid'], 'TPE0001');
      expect(uri.queryParameters.containsKey('name'), isFalse);
    });

    test('carries the first-paint hints when supplied', () {
      final uri = Uri.parse(
        AppRoutes.bikeStationLocation(
          stationUid: 'TPE0001',
          name: '捷運市政府站',
          lat: 25.0408,
          lon: 121.5679,
        ),
      );
      expect(uri.queryParameters['name'], '捷運市政府站');
      expect(uri.queryParameters['lat'], '25.0408');
      expect(uri.queryParameters['lon'], '121.5679');
    });
  });

  group('BusStopRouteArgs.from', () {
    test('parses a cold deep link from query parameters alone', () {
      final args = BusStopRouteArgs.from(
        const {'name': '台北車站', 'id': 'S18', 'city': 'Taipei'},
        null,
      );
      expect(args, isNotNull);
      expect(args!.stopName, '台北車站');
      expect(args.stopId, 'S18');
      expect(args.city, 'Taipei');
    });

    test('optional id and city may be absent', () {
      final args = BusStopRouteArgs.from(const {'name': '南港'}, null);
      expect(args, isNotNull);
      expect(args!.stopName, '南港');
      expect(args.stopId, isNull);
      expect(args.city, isNull);
      expect(args.lat, isNull);
      expect(args.lon, isNull);
    });

    test('parses the first-paint coordinates, unparseable ones stay null', () {
      final args = BusStopRouteArgs.from(
        const {'name': '南港', 'lat': '25.053', 'lon': '121.6067'},
        null,
      );
      expect(args!.lat, 25.053);
      expect(args.lon, 121.6067);
      final bad = BusStopRouteArgs.from(
        const {'name': '南港', 'lat': 'nope', 'lon': ''},
        null,
      );
      expect(bad!.lat, isNull);
      expect(bad.lon, isNull);
    });

    test('falls back to a legacy extra map when the query is empty', () {
      final args = BusStopRouteArgs.from(const {}, {
        'stopName': '南港',
        'stopId': 'S2',
        'city': 'Taipei',
      });
      expect(args, isNotNull);
      expect(args!.stopName, '南港');
      expect(args.stopId, 'S2');
      expect(args.city, 'Taipei');
    });

    test('returns null when neither query nor extra identify a stop', () {
      expect(BusStopRouteArgs.from(const {}, null), isNull);
      expect(BusStopRouteArgs.from(const {}, {'stopId': 'S2'}), isNull);
      expect(BusStopRouteArgs.from(const {}, 'not a map'), isNull);
    });
  });

  group('BikeStationRouteArgs.from', () {
    test('parses a cold deep link from query parameters alone', () {
      final args = BikeStationRouteArgs.from(const {'uid': 'TPE0001'}, null);
      expect(args, isNotNull);
      expect(args!.stationUid, 'TPE0001');
      expect(args.name, isNull);
      expect(args.lat, isNull);
    });

    test('parses the first-paint hints when present', () {
      final args = BikeStationRouteArgs.from(
        const {
          'uid': 'TPE0001',
          'name': '捷運市政府站',
          'lat': '25.0408',
          'lon': '121.5679',
        },
        null,
      );
      expect(args!.name, '捷運市政府站');
      expect(args.lat, 25.0408);
      expect(args.lon, 121.5679);
    });

    test('falls back to a legacy extra map when the query is empty', () {
      final args = BikeStationRouteArgs.from(const {}, {
        'stationUid': 'TPE0002',
      });
      expect(args, isNotNull);
      expect(args!.stationUid, 'TPE0002');
    });

    test('returns null when neither query nor extra identify a station', () {
      expect(BikeStationRouteArgs.from(const {}, null), isNull);
      expect(BikeStationRouteArgs.from(const {}, {'uid': 1}), isNull);
    });
  });

  group('GoRouteArgs', () {
    test('round-trips a destination through the URL builder', () {
      final uri = Uri.parse(
        AppRoutes.goToDestination(
          name: '北門國小',
          lat: 24.9928,
          lon: 121.3009,
        ),
      );
      expect(uri.path, AppRoutes.go);

      final args = GoRouteArgs.from(uri.queryParameters);
      expect(args, isNotNull);
      expect(args!.name, '北門國小');
      expect(args.lat, 24.9928);
      expect(args.lon, 121.3009);
    });

    test('a partial or malformed seed opens the planner empty, not broken', () {
      expect(GoRouteArgs.from(const {}), isNull);
      expect(
        GoRouteArgs.from(const {'destName': '北門國小', 'destLat': '24.99'}),
        isNull,
      );
      expect(
        GoRouteArgs.from(const {
          'destName': '北門國小',
          'destLat': 'x',
          'destLon': '121.3',
        }),
        isNull,
      );
      expect(
        GoRouteArgs.from(const {
          'destName': '',
          'destLat': '24.99',
          'destLon': '121.3',
        }),
        isNull,
      );
    });
  });

  group('near station', () {
    test('round-trips every field', () {
      final uri = Uri.parse(
        AppRoutes.nearStation(
          type: NearStationType.bike,
          id: 'YouBike2.0_500101001',
          name: '捷運市政府站(3號出口)',
          lat: 25.041,
          lon: 121.5677,
        ),
      );
      final args = NearStationRouteArgs.fromUri(uri);
      expect(args, isNotNull);
      expect(args!.type, NearStationType.bike);
      expect(args.id, 'YouBike2.0_500101001');
      expect(args.name, '捷運市政府站(3號出口)');
      expect(args.lat, closeTo(25.041, 1e-9));
      expect(args.lon, closeTo(121.5677, 1e-9));
    });

    test('survives an id that needs escaping', () {
      final uri = Uri.parse(
        AppRoutes.nearStation(type: NearStationType.bus, id: 'a/b c&d'),
      );
      expect(NearStationRouteArgs.fromUri(uri)?.id, 'a/b c&d');
    });

    test('an id alone is enough; the hints are optional', () {
      final args = NearStationRouteArgs.fromUri(
        Uri.parse(AppRoutes.nearStation(type: NearStationType.tra, id: '1000')),
      );
      expect(args?.type, NearStationType.tra);
      expect(args?.name, isNull);
      expect(args?.lat, isNull);
    });

    test('round-trips a return location for a caller it had to replace', () {
      final back = AppRoutes.searchLocation(query: '台北車站');
      final args = NearStationRouteArgs.fromUri(
        Uri.parse(
          AppRoutes.nearStation(
            type: NearStationType.bus,
            id: '1234',
            back: back,
          ),
        ),
      );
      expect(args?.back, back);
    });

    test('has no return location when the caller was the map itself', () {
      final args = NearStationRouteArgs.fromUri(
        Uri.parse(AppRoutes.nearStation(type: NearStationType.bus, id: '1')),
      );
      expect(args?.back, isNull);
    });

    test('is null for anything that does not name a station', () {
      for (final location in [
        '/',
        '/near',
        '/near/bus',
        '/near/bus/',
        '/near/nope/1',
        '/near/bus/1/extra',
        '/rail-query',
      ]) {
        expect(
          NearStationRouteArgs.fromUri(Uri.parse(location)),
          isNull,
          reason: location,
        );
      }
    });
  });

  group('home locations', () {
    test('cover the map and both of the sheet second layers', () {
      for (final location in [
        AppRoutes.home,
        AppRoutes.railQuery(),
        AppRoutes.nearStation(type: NearStationType.mrt, id: 'BL12'),
      ]) {
        expect(
          AppRoutes.isHomeLocation(Uri.parse(location)),
          isTrue,
          reason: location,
        );
      }
    });

    test('do not cover a screen of its own', () {
      for (final location in [AppRoutes.metro, AppRoutes.rail, '/settings']) {
        expect(
          AppRoutes.isHomeLocation(Uri.parse(location)),
          isFalse,
          reason: location,
        );
      }
    });
  });

  group('metro', () {
    test('round-trips the station id and the map mode', () {
      final uri = Uri.parse(
        AppRoutes.metroStation('BL15_BR10', mode: MetroMapMode.fare),
      );
      final args = MetroRouteArgs.from(
        {'id': uri.pathSegments.last},
        uri.queryParameters,
      );
      expect(args.stationId, 'BL15_BR10');
      expect(args.mode, MetroMapMode.fare);
    });

    test('the bare map has no station and the default mode', () {
      final uri = Uri.parse(AppRoutes.metroLocation());
      final args = MetroRouteArgs.from(const {}, uri.queryParameters);
      expect(args.stationId, isNull);
      expect(args.mode, MetroMapMode.time);
    });

    test('an unreadable mode falls back rather than failing', () {
      final args = MetroRouteArgs.from(const {}, const {'mode': 'sideways'});
      expect(args.mode, MetroMapMode.time);
    });

    test('every line-map station resolves from its own name', () {
      for (final station in metroMapStations) {
        expect(
          metroStationIdForName(station.name),
          isNotNull,
          reason: station.name,
        );
      }
    });
  });

  group('rail timetable', () {
    test('round-trips a full submitted O/D query', () {
      final date = DateTime(2026, 8, 6, 17, 30);
      final uri = Uri.parse(
        AppRoutes.railLocation(
          system: RailSystem.thsr,
          originName: '台北',
          originId: '1000',
          destName: '左營',
          destId: '1210',
          date: date,
          isDeparture: false,
          submit: true,
        ),
      );
      final args = RailRouteArgs.from(uri.queryParameters);
      expect(args.system, RailSystem.thsr);
      expect(args.originName, '台北');
      expect(args.originId, '1000');
      expect(args.destName, '左營');
      expect(args.destId, '1210');
      // Minute precision, so the time-of-day cutoff survives the link.
      expect(args.date, date);
      expect(args.isDeparture, isFalse);
      expect(args.submit, isTrue);
    });

    test('a station preset carries an origin and does not submit', () {
      final args = RailRouteArgs.from(
        Uri.parse(
          AppRoutes.railLocation(
            system: RailSystem.tra,
            originName: '花蓮',
            originId: '7000',
          ),
        ).queryParameters,
      );
      expect(args.originName, '花蓮');
      expect(args.destName, isEmpty);
      expect(args.submit, isFalse);
      // Departure is the default, so a location that says nothing means it.
      expect(args.isDeparture, isTrue);
      // No date means "now", resolved at the screen.
      expect(args.date, isNull);
    });

    test('a bare /rail opens the empty form', () {
      final args = RailRouteArgs.from(const {});
      expect(args.originName, isEmpty);
      expect(args.submit, isFalse);
      expect(args.system, RailSystem.tra);
    });
  });

  group('rail train', () {
    test('round-trips the train, system and service date', () {
      final uri = Uri.parse(
        AppRoutes.railTrain(
          '1234',
          system: RailSystem.thsr,
          date: DateTime(2026, 8, 6),
        ),
      );
      final args = RailTrainRouteArgs.from({
        'trainNo': uri.pathSegments.last,
      }, uri.queryParameters);
      expect(args, isNotNull);
      expect(args!.trainNo, '1234');
      expect(args.system, RailSystem.thsr);
      expect(args.date, DateTime(2026, 8, 6));
    });

    test('is null without a train number', () {
      expect(RailTrainRouteArgs.from(const {}, const {}), isNull);
      expect(RailTrainRouteArgs.from(const {'trainNo': ''}, const {}), isNull);
    });
  });

  group('rail query sheet', () {
    test('round-trips its station preset', () {
      final args = RailQueryRouteArgs.from(
        Uri.parse(
          AppRoutes.railQuery(
            system: RailSystem.thsr,
            originName: '板橋',
            originId: '1010',
          ),
        ).queryParameters,
      );
      expect(args.system, RailSystem.thsr);
      expect(args.originName, '板橋');
      expect(args.originId, '1010');
    });
  });

  group('rail system', () {
    test('falls back to TRA for anything unrecognised', () {
      expect(railSystemFromName(null), RailSystem.tra);
      expect(railSystemFromName(''), RailSystem.tra);
      expect(railSystemFromName('metro'), RailSystem.tra);
      expect(railSystemFromName('thsr'), RailSystem.thsr);
    });
  });

  group('search', () {
    test('carries a query and omits an absent one', () {
      expect(AppRoutes.searchLocation(query: '台北車站'), contains('q='));
      expect(
        Uri.parse(
          AppRoutes.searchLocation(query: '台北車站'),
        ).queryParameters['q'],
        '台北車站',
      );
      expect(AppRoutes.searchLocation(), AppRoutes.search);
    });
  });

  group('deep links', () {
    test('leaves an in-app location alone', () {
      expect(
        normalizeDeepLink(Uri.parse('/metro/station/BL12?mode=map')),
        null,
      );
    });

    test('strips the scheme from the canonical three-slash form', () {
      expect(
        normalizeDeepLink(Uri.parse('$appLinkScheme:///metro/station/BL12')),
        '/metro/station/BL12',
      );
    });

    test('keeps query parameters and decodes path segments', () {
      expect(
        normalizeDeepLink(
          Uri.parse('$appLinkScheme:///rail/train/152?sys=tra'),
        ),
        '/rail/train/152?sys=tra',
      );
    });

    test('folds an authority back into the path', () {
      expect(
        normalizeDeepLink(Uri.parse('$appLinkScheme://bus/route/abc')),
        '/bus/route/abc',
      );
    });

    test('a bare scheme opens home', () {
      expect(normalizeDeepLink(Uri.parse('$appLinkScheme://')), AppRoutes.home);
    });

    test('an https app link drops the domain and the prefix', () {
      expect(
        normalizeDeepLink(
          Uri.parse(
            'https://$appLinkHost$appLinkPathPrefix/metro/station/BL12',
          ),
        ),
        '/metro/station/BL12',
      );
    });

    test('an https app link keeps its query', () {
      expect(
        normalizeDeepLink(
          Uri.parse('https://$appLinkHost$appLinkPathPrefix/rail?sys=thsr'),
        ),
        '/rail?sys=thsr',
      );
    });

    test('the bare prefix opens home', () {
      expect(
        normalizeDeepLink(Uri.parse('https://$appLinkHost$appLinkPathPrefix')),
        AppRoutes.home,
      );
    });

    test('a path that only looks like the prefix is left whole', () {
      expect(
        normalizeDeepLink(Uri.parse('https://$appLinkHost/apple/pie')),
        '/apple/pie',
      );
    });
  });
}
