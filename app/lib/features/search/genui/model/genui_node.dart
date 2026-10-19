sealed class GenUiNode {
  const GenUiNode();

  static GenUiNode? fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    return _factories[type]?.call(json);
  }

  static final _factories = <String, GenUiNode Function(Map<String, Object?>)>{
    'heading': (json) => GenUiHeading(json['text'] as String? ?? ''),
    'text': (json) => GenUiText(json['text'] as String? ?? ''),
    'route': (json) => GenUiRoute(
      title: json['title'] as String? ?? '',
      badges: ((json['badges'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      refUid: _refUid(json),
    ),
    'step': (json) => GenUiStep(
      kind: GenUiStepKind.from(json['kind'] as String?),
      text: json['text'] as String? ?? '',
    ),
    'chip': (json) => GenUiChip(
      label: json['label'] as String? ?? '',
      query: json['query'] as String? ?? '',
      refUid: _refUid(json),
    ),
    'divider': (_) => const GenUiDivider(),
  };

  static List<GenUiNode> listFrom(Object? nodes) {
    if (nodes is! List) return const [];
    return nodes
        .whereType<Map<Object?, Object?>>()
        .map((m) => fromJson(Map<String, Object?>.from(m)))
        .whereType<GenUiNode>()
        .toList();
  }

  static String? _refUid(Map<String, Object?> json) {
    final v = (json['refUid'] as String? ?? '').trim();
    return v.isEmpty ? null : v;
  }
}

class GenUiHeading extends GenUiNode {
  const GenUiHeading(this.text);
  final String text;
}

class GenUiText extends GenUiNode {
  const GenUiText(this.text);
  final String text;
}

class GenUiRoute extends GenUiNode {
  const GenUiRoute({required this.title, required this.badges, this.refUid});
  final String title;
  final List<String> badges;
  final String? refUid;
}

enum GenUiStepKind {
  board,
  ride,
  walk,
  alight;

  static GenUiStepKind from(String? value) => switch (value) {
    'ride' => GenUiStepKind.ride,
    'walk' => GenUiStepKind.walk,
    'alight' => GenUiStepKind.alight,
    _ => GenUiStepKind.board,
  };
}

class GenUiStep extends GenUiNode {
  const GenUiStep({required this.kind, required this.text});
  final GenUiStepKind kind;
  final String text;
}

class GenUiChip extends GenUiNode {
  const GenUiChip({required this.label, required this.query, this.refUid});
  final String label;
  final String query;
  final String? refUid;
}

class GenUiDivider extends GenUiNode {
  const GenUiDivider();
}
