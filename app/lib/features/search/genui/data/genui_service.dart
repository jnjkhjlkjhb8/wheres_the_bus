import 'package:firebase_ai/firebase_ai.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';

/// AI 回覆的處理階段,供 UI 顯示進度文字。
enum GenUiPhase { thinking, searching, composing }

/// AI 最終回覆:UI 節點與其引用的真實查詢結果(uid → result)。
class GenUiAnswer {
  const GenUiAnswer({required this.nodes, required this.refs});
  final List<GenUiNode> nodes;
  final Map<String, SearchResult> refs;
}

class GenUiService {
  const GenUiService();
  static const instance = GenUiService();
  static const _model = 'gemini-3.5-flash';
  static const _maxTurns = 6;

  /// Remote Config-backed so a prompt regression can be fixed without a
  /// release; falls back to [AppConfig.defaults] when Firebase is off.
  static String get _systemPrompt =>
      AppConfig.getString(AppConfig.genUiSystemPromptKey);

  GenerativeModel _build() {
    final node = Schema.object(
      properties: {
        'type': Schema.enumString(
          enumValues: ['heading', 'text', 'route', 'step', 'chip', 'divider'],
          description: '節點種類',
        ),
        'text': Schema.string(description: 'heading / text / step 的文字'),
        'title': Schema.string(description: 'route 的標題'),
        'badges': Schema.array(
          items: Schema.string(),
          description: 'route 的路線或路線色標籤',
        ),
        'kind': Schema.enumString(
          enumValues: ['board', 'ride', 'walk', 'alight'],
          description: 'step 的圖示種類',
        ),
        'label': Schema.string(description: 'chip 顯示文字'),
        'query': Schema.string(description: 'chip 點擊後帶入搜尋框的字串'),
        'refUid': Schema.string(
          description: 'route / chip 對應的 searchTransit 結果 uid,原樣帶回',
        ),
      },
      optionalProperties: [
        'text',
        'title',
        'badges',
        'kind',
        'label',
        'query',
        'refUid',
      ],
    );

    return FirebaseAI.googleAI().generativeModel(
      model: _model,
      systemInstruction: Content.system(_systemPrompt),
      tools: [
        Tool.functionDeclarations([
          FunctionDeclaration(
            'searchTransit',
            '向後端查詢公車路線、各類車站、YouBike 站點。回傳符合的結果清單。',
            parameters: {
              'query': Schema.string(description: '搜尋關鍵字,例如站名或路線號碼'),
            },
          ),
          FunctionDeclaration(
            'renderUI',
            '把最終回覆渲染成卡片。收到此呼叫即視為完成。',
            parameters: {
              'nodes': Schema.array(
                items: node,
                description: '依序排列的 UI 節點',
              ),
            },
          ),
        ]),
      ],
    );
  }

  Future<GenUiAnswer> ask(
    String prompt, {
    void Function(GenUiPhase phase, String? query)? onPhase,
  }) async {
    final refs = <String, SearchResult>{};
    onPhase?.call(GenUiPhase.thinking, null);
    final chat = _build().startChat();
    var response = await chat.sendMessage(Content.text(prompt));

    for (var turn = 0; turn < _maxTurns; turn++) {
      final calls = response.functionCalls.toList();
      if (calls.isEmpty) break;

      for (final call in calls) {
        if (call.name == 'renderUI') {
          return GenUiAnswer(
            nodes: GenUiNode.listFrom(call.args['nodes']),
            refs: refs,
          );
        }
      }

      final replies = <FunctionResponse>[];
      for (final call in calls) {
        replies.add(
          FunctionResponse(call.name, await _dispatch(call, refs, onPhase)),
        );
      }
      onPhase?.call(GenUiPhase.composing, null);
      response = await chat.sendMessage(Content.functionResponses(replies));
    }

    return GenUiAnswer(nodes: const [], refs: refs);
  }

  Future<Map<String, Object?>> _dispatch(
    FunctionCall call,
    Map<String, SearchResult> refs,
    void Function(GenUiPhase phase, String? query)? onPhase,
  ) async {
    if (call.name != 'searchTransit') {
      return {'error': 'unknown tool'};
    }
    try {
      final query = (call.args['query'] as String? ?? '').trim();
      if (query.isEmpty) return {'results': const []};
      onPhase?.call(GenUiPhase.searching, query);
      final results = await SearchRepository.instance.search(query, limit: 8);
      for (final r in results) {
        if (r.uid.isNotEmpty) refs[r.uid] = r;
      }
      return {
        'results': results
            .map(
              (r) => {
                'uid': r.uid,
                'type': r.type.name,
                'name': r.name,
                'subtitle': r.subtitle,
                if (r.city != null) 'city': r.city,
              },
            )
            .toList(),
      };
    } on Object catch (e) {
      return {'error': e.toString()};
    }
  }
}
