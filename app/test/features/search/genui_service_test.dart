import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/genui/data/genui_service.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';

Map<String, Object?> _call(String name, Map<String, Object?> args) => {
  'functionCall': {'name': name, 'args': args},
};

http.Response _response(List<Map<String, Object?>> parts) => http.Response(
  jsonEncode({
    'candidates': [
      {
        'content': {'role': 'model', 'parts': parts},
        'finishReason': 'STOP',
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

List<Map<String, dynamic>> _replies(Map<String, dynamic> request) =>
    (request['contents'] as List)
        .expand((content) => (content as Map)['parts'] as List)
        .where((part) => (part as Map).containsKey('functionResponse'))
        .map(
          (part) => Map<String, dynamic>.from(
            (part as Map)['functionResponse'] as Map,
          ),
        )
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPlatform = debugDefaultTargetPlatformOverride;

  setUpAll(() async {
    setupFirebaseCoreMocks();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await Firebase.initializeApp();
  });
  tearDownAll(() {
    debugDefaultTargetPlatformOverride = originalPlatform;
    TestFirebaseCoreHostApi.setUp(null);
  });

  test(
    'native SDK sends schema, resolves results and renders directly',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final phases = <(GenUiPhase, String?)>[];
      final searches = <(String, int, String?)>[];
      const result = SearchResult(
        type: SearchResultType.busRoute,
        uid: 'route-307',
        name: '307',
        subtitle: 'A → B',
        city: 'Taipei',
      );
      const noCity = SearchResult(
        type: SearchResultType.busStation,
        uid: 'station',
        name: 'Station',
        subtitle: '',
      );
      const noIdentity = SearchResult(
        type: SearchResultType.busRoute,
        uid: '',
        name: 'Incomplete',
        subtitle: '',
      );
      final repository = SearchRepository(
        httpFetch: (query, limit, city) async {
          searches.add((query, limit, city));
          return [result, noCity, noIdentity];
        },
      );
      final client = MockClient((request) async {
        expect(
          request.url.path,
          endsWith('/models/gemini-3.5-flash:generateContent'),
        );
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (bodies.length == 1) {
          return _response([
            _call('searchTransit', {'query': ' 307 '}),
          ]);
        }
        return _response([
          _call('renderUI', {
            'nodes': [
              {'type': 'heading', 'text': 'Routes'},
              {
                'type': 'route',
                'title': 'AI title',
                'refUid': 'route-307',
                'badges': ['bus'],
              },
            ],
          }),
        ]);
      });
      addTearDown(client.close);
      final answer =
          await GenUiService(httpClient: client, repository: repository).ask(
            'which bus?',
            onPhase: (phase, query) => phases.add((phase, query)),
          );
      expect(searches, [('307', 8, null)]);
      expect(phases, [
        (GenUiPhase.thinking, null),
        (GenUiPhase.searching, '307'),
        (GenUiPhase.composing, null),
      ]);
      expect(answer.refs, {'route-307': result, 'station': noCity});
      expect(answer.nodes, hasLength(2));
      expect((answer.nodes.first as GenUiHeading).text, 'Routes');
      expect((answer.nodes.last as GenUiRoute).refUid, 'route-307');
      expect(bodies, hasLength(2));
      expect(bodies.first['systemInstruction'], {
        'role': 'system',
        'parts': [
          {'text': AppConfig.getString(AppConfig.genUiSystemPromptKey)},
        ],
      });
      final declarations =
          ((bodies.first['tools'] as List).single
                  as Map)['functionDeclarations']
              as List;
      expect(declarations.map((declaration) => (declaration as Map)['name']), [
        'searchTransit',
        'renderUI',
      ]);
      final render = declarations.last as Map;
      final node =
          (((render['parameters'] as Map)['properties'] as Map)['nodes']
                  as Map)['items']
              as Map;
      expect((node['properties'] as Map).keys, [
        'type',
        'text',
        'title',
        'badges',
        'kind',
        'label',
        'query',
        'refUid',
      ]);
      expect(((node['properties'] as Map)['type'] as Map)['enum'], [
        'heading',
        'text',
        'route',
        'step',
        'chip',
        'divider',
      ]);
      expect(((node['properties'] as Map)['kind'] as Map)['enum'], [
        'board',
        'ride',
        'walk',
        'alight',
      ]);
      expect(node['required'], ['type']);
      final properties = node['properties'] as Map;
      expect(
        (properties['text'] as Map)['description'],
        'heading / text / step 的文字',
      );
      expect(
        (properties['refUid'] as Map)['description'],
        'route / chip 對應的 searchTransit 結果 uid,原樣帶回',
      );
      final reply = _replies(bodies.last).single;
      expect(reply['name'], 'searchTransit');
      expect(reply['response'], {
        'results': [
          {
            'uid': 'route-307',
            'type': 'busRoute',
            'name': '307',
            'subtitle': 'A → B',
            'city': 'Taipei',
          },
          {
            'uid': 'station',
            'type': 'busStation',
            'name': 'Station',
            'subtitle': '',
          },
          {'uid': '', 'type': 'busRoute', 'name': 'Incomplete', 'subtitle': ''},
        ],
      });
    },
  );

  test(
    'renderUI in a multi-tool response wins before any search is dispatched',
    () async {
      var searches = 0;
      final repository = SearchRepository(
        httpFetch: (_, _, _) async {
          searches++;
          return [];
        },
      );
      final client = MockClient(
        (_) async => _response([
          _call('searchTransit', {'query': '307'}),
          _call('renderUI', {
            'nodes': [
              {'type': 'text', 'text': 'Finished'},
            ],
          }),
        ]),
      );
      addTearDown(client.close);
      final answer = await GenUiService(
        httpClient: client,
        repository: repository,
      ).ask('query');
      expect(searches, 0);
      expect(answer.refs, isEmpty);
      expect((answer.nodes.single as GenUiText).text, 'Finished');
    },
  );

  for (final entry in <(String, Map<String, Object?>, String?)>[
    ('unknownTool', {}, 'unknown tool'),
    ('searchTransit', {'query': '   '}, null),
    ('searchTransit', {'query': 42}, 'String'),
    ('searchTransit', {'query': 'unavailable'}, 'UnknownError'),
  ]) {
    test(
      'tool reply preserves the failure or empty-query result for ${entry.$2}',
      () async {
        Map<String, dynamic>? reply;
        var requests = 0;
        final repository = SearchRepository(
          httpFetch: (_, _, _) async => throw StateError('down'),
        );
        final client = MockClient((request) async {
          if (requests++ == 0) return _response([_call(entry.$1, entry.$2)]);
          reply = _replies(
            jsonDecode(request.body) as Map<String, dynamic>,
          ).single;
          return _response([
            {'text': 'No UI'},
          ]);
        });
        addTearDown(client.close);
        final answer = await GenUiService(
          httpClient: client,
          repository: repository,
        ).ask('query');
        expect(answer.nodes, isEmpty);
        expect(answer.refs, isEmpty);
        expect(reply!['name'], entry.$1);
        final response = reply!['response'] as Map;
        if (entry.$3 == null) {
          expect(response, {'results': <Object?>[]});
        } else {
          expect(response['error'], contains(entry.$3));
        }
      },
    );
  }

  test(
    'an answer with no function calls stops after its first native request',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return _response([
          {'text': 'Plain answer'},
        ]);
      });
      addTearDown(client.close);
      final answer = await GenUiService(httpClient: client).ask('query');
      expect(requests, 1);
      expect(answer.nodes, isEmpty);
      expect(answer.refs, isEmpty);
    },
  );

  test('a model which never renders stops after six tool turns', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _response([_call('unknownTool', {})]);
    });
    addTearDown(client.close);
    final answer = await GenUiService(httpClient: client).ask('query');
    expect(requests, 7);
    expect(answer.nodes, isEmpty);
  });

  test('upstream transport failure reaches the caller', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('AI offline'),
    );
    addTearDown(client.close);
    await expectLater(
      GenUiService(httpClient: client).ask('query'),
      throwsA(isA<Exception>()),
    );
  });
}
