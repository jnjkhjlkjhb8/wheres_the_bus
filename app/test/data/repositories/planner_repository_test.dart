import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);

  final String body;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('renders the capabilities the router names, and nothing else', () async {
    final repo = PlannerRepository(
      fetchBody: () async => {
        'backend': 'motis',
        'capabilities': [
          'transitModes',
          'maxTransfers',
          'carryBike',
          // A name this build has never heard of. Ignoring it is the whole
          // point of serving the list: the server can add one without
          // breaking an app that is already installed.
          'somethingAddedNextYear',
        ],
      },
    );

    final capabilities = await repo.capabilities();
    expect(capabilities.has(PlannerCapabilities.maxTransfers), isTrue);
    expect(capabilities.has(PlannerCapabilities.carryBike), isTrue);
    expect(capabilities.has(PlannerCapabilities.avoidReservation), isFalse);
    expect(capabilities.has('somethingAddedNextYear'), isTrue);
  });

  test('an unreachable router leaves the shared five offered', () async {
    final repo = PlannerRepository(
      fetchBody: () async => throw Exception('offline'),
    );

    final capabilities = await repo.capabilities();
    // The five both planners honour still work, so hiding them would be the
    // wrong failure: the rider loses controls that would have functioned.
    expect(capabilities.has('transitModes'), isTrue);
    expect(capabilities.has('pricePreference'), isTrue);
    // The MOTIS-only ones stay hidden rather than being guessed at — a
    // control that silently does nothing is worse than a missing one.
    expect(capabilities.has(PlannerCapabilities.maxTransfers), isFalse);
    expect(capabilities.has(PlannerCapabilities.earlierLater), isFalse);
  });

  test('a body with no capabilities list degrades the same way', () async {
    final repo = PlannerRepository(fetchBody: () async => {'backend': 'tdx'});

    final capabilities = await repo.capabilities();
    expect(capabilities.has('transitModes'), isTrue);
    expect(capabilities.has(PlannerCapabilities.carryBike), isFalse);
  });

  test('opening the planner twice in a minute only asks once', () async {
    var calls = 0;
    final repo = PlannerRepository(
      fetchBody: () async {
        calls++;
        return {
          'capabilities': ['transitModes'],
        };
      },
    );

    await repo.capabilities();
    await repo.capabilities();
    await repo.capabilities();

    expect(
      calls,
      1,
      reason: 'the endpoint sets max-age=20; the app must honour it',
    );
  });
  group('cache window', () {
    late DateTime clock;
    late int calls;
    late PlannerRepository repo;

    setUp(() {
      clock = DateTime(2026, 10, 14, 9);
      calls = 0;
      repo = PlannerRepository(
        now: () => clock,
        fetchBody: () async {
          calls++;
          return {
            'capabilities': ['gen$calls'],
          };
        },
      );
    });

    test('serves the cached list until twenty seconds have passed', () async {
      final first = await repo.capabilities();
      expect(first.has('gen1'), isTrue);

      clock = clock.add(const Duration(seconds: 19, milliseconds: 999));
      final stillFresh = await repo.capabilities();
      expect(calls, 1);
      expect(stillFresh, same(first));
    });

    test('asks again exactly when the window closes', () async {
      await repo.capabilities();
      clock = clock.add(const Duration(seconds: 20));
      final refreshed = await repo.capabilities();
      expect(calls, 2);
      expect(refreshed.has('gen2'), isTrue);
      expect(refreshed.has('gen1'), isFalse);
    });

    test('a refresh restarts the window from the moment it landed', () async {
      await repo.capabilities();
      clock = clock.add(const Duration(seconds: 30));
      await repo.capabilities();
      clock = clock.add(const Duration(seconds: 19));
      await repo.capabilities();
      expect(calls, 2);
      clock = clock.add(const Duration(seconds: 1));
      await repo.capabilities();
      expect(calls, 3);
    });
  });

  test('a capabilities value that is not a list degrades to shared', () async {
    for (final body in <Map<String, dynamic>?>[
      {'capabilities': 'maxTransfers'},
      {
        'capabilities': {'maxTransfers': true},
      },
      null,
    ]) {
      final repo = PlannerRepository(fetchBody: () async => body);
      final capabilities = await repo.capabilities();
      expect(capabilities.has('transitModes'), isTrue, reason: '$body');
      expect(capabilities.has(PlannerCapabilities.maxTransfers), isFalse);
    }
  });

  test('entries that are not names are skipped, the rest are kept', () async {
    final repo = PlannerRepository(
      fetchBody: () async => {
        'capabilities': ['carryBike', 7, null, 'maxTransfers'],
      },
    );
    final capabilities = await repo.capabilities();
    expect(capabilities.has('carryBike'), isTrue);
    expect(capabilities.has('maxTransfers'), isTrue);
    expect(capabilities.has('transitModes'), isFalse);
  });

  test('an empty list offers nothing, not even the shared five', () async {
    final repo = PlannerRepository(
      fetchBody: () async => {'capabilities': <String>[]},
    );
    final capabilities = await repo.capabilities();
    expect(capabilities.has('transitModes'), isFalse);
  });

  test('the shared set names the five both planners honour', () {
    const shared = PlannerCapabilities.shared();
    for (final name in [
      'transitModes',
      'itineraryCount',
      'transferWindow',
      'firstLastMile',
      'pricePreference',
    ]) {
      expect(shared.has(name), isTrue, reason: name);
    }
    for (final name in [
      PlannerCapabilities.maxTransfers,
      PlannerCapabilities.avoidReservation,
      PlannerCapabilities.carryBike,
      PlannerCapabilities.earlierLater,
      PlannerCapabilities.legAlternatives,
    ]) {
      expect(shared.has(name), isFalse, reason: name);
    }
  });

  test('the capability names match what the router serves', () {
    expect(PlannerCapabilities.maxTransfers, 'maxTransfers');
    expect(PlannerCapabilities.avoidReservation, 'avoidReservation');
    expect(PlannerCapabilities.carryBike, 'carryBike');
    expect(PlannerCapabilities.earlierLater, 'earlierLater');
    expect(PlannerCapabilities.legAlternatives, 'legAlternatives');
  });

  test(
    'the default fetch reads /api/planner through the shared client',
    () async {
      final dio = HttpClient.instance.dio;
      final original = dio.httpClientAdapter;
      final adapter = _JsonAdapter(
        jsonEncode({
          'capabilities': ['earlierLater'],
        }),
      );
      dio.httpClientAdapter = adapter;
      addTearDown(() => dio.httpClientAdapter = original);

      final capabilities = await PlannerRepository().capabilities();

      expect(adapter.paths, ['/api/planner']);
      expect(capabilities.has(PlannerCapabilities.earlierLater), isTrue);
      expect(capabilities.has('transitModes'), isFalse);
    },
  );
}
