import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_affinity_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';

SearchResult _result(
  String uid, {
  SearchResultType type = SearchResultType.busRoute,
}) => SearchResult(type: type, uid: uid, name: 'Name $uid', subtitle: 'Taipei');

void main() {
  const affinity = SearchAffinityRepository.instance;
  const recent = SearchRecentRepository.instance;
  late Directory directory;
  late Box<dynamic> settings;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('bus-search-history-');
    Hive.init(directory.path);
    settings = await Hive.openBox<dynamic>('settings');
  });

  setUp(() => settings.clear());

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('closed settings keeps history and affinity unavailable', () async {
    await settings.close();
    try {
      expect(HiveStore.settingsReady, isFalse);
      expect(affinity.all(), isEmpty);
      expect(affinity.frequent(), isEmpty);
      await affinity.record(_result('a'), query: '307', now: DateTime(2026));
      await affinity.clear();
      expect(recent.all(), isEmpty);
      await recent.add(_result('a'));
      await recent.remove(_result('a'));
      await recent.restore(_result('a'), 0);
      await recent.clear();
    } finally {
      settings = await Hive.openBox<dynamic>('settings');
    }
    expect(settings.keys, isEmpty);
  });

  test(
    'stored affinity drops incomplete entries and preserves optional fields',
    () async {
      final valid = _result('valid');
      await settings.put('search_affinity', {
        7: {'r': valid.toStorageMap()},
        'not a map': 'broken',
        'no result': {'r': 7},
        'unknown type': {
          'r': {'type': 'old-category', 'uid': 'old', 'name': 'Old'},
        },
        'empty uid': {
          'r': {'type': 'busRoute', 'uid': '', 'name': 'Missing'},
        },
        'empty name': {
          'r': {'type': 'busRoute', 'uid': 'missing', 'name': ''},
        },
        valid.storageKey: {
          'r': valid.toStorageMap(),
          'n': 3.8,
          't': 42.9,
          'q': ['307', 5, 'taipei'],
          'h': (1 << 7) | (1 << 23),
        },
        'defaults': {'r': _result('defaults').toStorageMap()},
      });
      final parsed = affinity.all();
      expect(parsed.keys, [valid.storageKey, 'defaults']);
      final entry = parsed[valid.storageKey]!;
      expect(entry.result, valid);
      expect(entry.picks, 3);
      expect(entry.lastPickedMs, 42);
      expect(entry.queries, ['307', 'taipei']);
      expect(entry.pickedAtHour(7), isTrue);
      expect(entry.pickedAtHour(23), isTrue);
      expect(entry.pickedAtHour(8), isFalse);
      expect(entry.matchesQuery('TAI'), isTrue);
      expect(entry.matchesQuery('3070'), isTrue);
      expect(entry.matchesQuery(''), isFalse);
      expect(entry.matchesQuery('other'), isFalse);
      expect(parsed['defaults']!.picks, 0);
      expect(parsed['defaults']!.lastPickedMs, 0);
      expect(parsed['defaults']!.queries, isEmpty);
      expect(parsed['defaults']!.hourMask, 0);
      await settings.put('search_affinity', 17);
      expect(affinity.all(), isEmpty);
    },
  );

  test(
    'record normalizes queries, moves repeats, caps them and accumulates hours',
    () async {
      final result = _result('a');
      for (final query in [' A ', 'B', 'C', 'D', 'b', '   ']) {
        await affinity.record(
          result,
          query: query,
          now: DateTime(2026, 10, 10, 7),
        );
      }
      await affinity.record(
        result,
        query: 'D',
        now: DateTime(2026, 10, 10, 19),
      );
      final entry = affinity.all()[result.storageKey]!;
      expect(entry.picks, 7);
      expect(entry.queries, ['d', 'b', 'c']);
      expect(
        entry.lastPickedMs,
        DateTime(2026, 10, 10, 19).millisecondsSinceEpoch,
      );
      expect(entry.pickedAtHour(7), isTrue);
      expect(entry.pickedAtHour(19), isTrue);
      expect(entry.pickedAtHour(20), isFalse);
      await affinity.clear();
      expect(affinity.all(), isEmpty);
    },
  );

  test('frequent sorts by picks then recency and limits the result', () async {
    await affinity.record(
      _result('older'),
      query: '',
      now: DateTime(2026),
    );
    await affinity.record(
      _result('newer'),
      query: '',
      now: DateTime(2026, 1, 2),
    );
    await affinity.record(
      _result('often'),
      query: '',
      now: DateTime(2026),
    );
    await affinity.record(
      _result('often'),
      query: '',
      now: DateTime(2026),
    );
    expect(affinity.frequent().map((result) => result.uid), [
      'often',
      'newer',
      'older',
    ]);
    expect(affinity.frequent(limit: 1).single.uid, 'often');
    expect(affinity.frequent(limit: 0), isEmpty);
  });

  test(
    'affinity evicts the oldest entry only when the 100-entry cap is exceeded',
    () async {
      final initial = <String, Object?>{};
      for (var i = 0; i < 100; i++) {
        final result = _result('$i');
        initial[result.storageKey] = {'r': result.toStorageMap(), 't': i};
      }
      await settings.put('search_affinity', initial);
      expect(affinity.all(), hasLength(100));
      await affinity.record(_result('100'), query: 'new', now: DateTime(2026));
      final entries = affinity.all();
      expect(entries, hasLength(100));
      expect(entries.containsKey('busRoute:0'), isFalse);
      expect(entries.containsKey('busRoute:1'), isTrue);
      expect(entries.containsKey('busRoute:100'), isTrue);
    },
  );

  test('history drops invalid records and round-trips coordinates', () async {
    const located = SearchResult(
      type: SearchResultType.bikeStation,
      uid: 'bike',
      name: 'Bike',
      subtitle: '',
      city: 'Taipei',
      lat: 25,
      lon: 121,
    );
    await settings.put('recent_search_results', [
      7,
      {'type': 'old-category'},
      {'type': 'busRoute', 'uid': ''},
      located.toStorageMap(),
    ]);
    expect(recent.all(), [located]);
    expect(recent.all().single.props, located.props);
    await settings.put('recent_search_results', 17);
    expect(recent.all(), isEmpty);
  });

  test(
    'history keeps eight entries and deduplicates by category and identifier',
    () async {
      for (var i = 0; i < 9; i++) {
        await recent.add(_result('$i'));
      }
      expect(recent.all().map((result) => result.uid), [
        '8',
        '7',
        '6',
        '5',
        '4',
        '3',
        '2',
        '1',
      ]);
      await recent.add(_result('5'));
      expect(recent.all().map((result) => result.uid), [
        '5',
        '8',
        '7',
        '6',
        '4',
        '3',
        '2',
        '1',
      ]);
      final station = _result('5', type: SearchResultType.busStation);
      await recent.add(station);
      await recent.remove(_result('5'));
      expect(recent.all().first, station);
      expect(recent.all().where((result) => result.uid == '5'), [station]);
      await recent.clear();
      expect(recent.all(), isEmpty);
    },
  );

  test(
    'restoring a removed row clamps the index and keeps the history cap',
    () async {
      await recent.add(_result('a'));
      await recent.add(_result('b'));
      await recent.restore(_result('a'), 99);
      expect(recent.all().map((result) => result.uid), ['b', 'a']);
      await recent.restore(_result('a'), -1);
      expect(recent.all().map((result) => result.uid), ['a', 'b']);
      for (var i = 0; i < 8; i++) {
        await recent.add(_result('$i'));
      }
      await recent.restore(_result('last'), 99);
      expect(recent.all(), hasLength(8));
      expect(recent.all().any((result) => result.uid == 'last'), isFalse);
    },
  );

  test(
    'a full set of 100 results is kept whole, in the order recorded',
    () async {
      for (var i = 0; i < 100; i++) {
        await affinity.record(
          _result('r$i'),
          query: 'q',
          now: DateTime(2026, 1, 1, 0, i),
        );
      }

      final stored = settings.get('search_affinity') as Map<dynamic, dynamic>;
      expect(stored.keys.toList(), [
        for (var i = 0; i < 100; i++) _result('r$i').storageKey,
      ]);
    },
  );

  test('past 100 results the least recently picked one is dropped', () async {
    for (var i = 0; i < 101; i++) {
      await affinity.record(
        _result('r$i'),
        query: 'q',
        now: DateTime(2026, 1, 1, 0, i),
      );
    }

    final stored = settings.get('search_affinity') as Map<dynamic, dynamic>;
    expect(stored, hasLength(100));
    expect(stored.containsKey(_result('r0').storageKey), isFalse);
    expect(stored.containsKey(_result('r100').storageKey), isTrue);
  });
}
