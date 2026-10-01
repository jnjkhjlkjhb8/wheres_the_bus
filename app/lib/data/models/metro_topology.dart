import 'package:wheres_the_bus/data/models/metro_map_models.dart';

/// A single station on a train's forward path, as offered in the 下車站 picker.
class MetroPathStop {
  const MetroPathStop({
    required this.id,
    required this.name,
    required this.line,
  });

  /// Single-line TDX code, e.g. `BL13`.
  final String id;
  final String name;

  /// Line letters the [id] belongs to, e.g. `BL`.
  final String line;
}

abstract final class MetroTopology {
  /// Single-line code → station name, expanded from the interchange-combined
  /// ids in [metroMapStations] (e.g. `BL12_R10` → `BL12` and `R10`).
  static final Map<String, String> stationNames = _buildNames();

  static const Map<String, List<_Branch>> _branches = {
    'O': [
      _Branch(connect: 'O12', chain: ['O50', 'O51', 'O52', 'O53', 'O54']),
    ],
    'R': [
      _Branch(connect: 'R22', chain: ['R22A']),
    ],
    'G': [
      _Branch(connect: 'G03', chain: ['G03A']),
    ],
  };

  static List<MetroPathStop> aheadStations({
    required String line,
    required String boardCode,
    required String terminalCode,
  }) {
    if (boardCode.isEmpty || terminalCode.isEmpty) return const [];
    final adjacency = _adjacency(line);
    if (!adjacency.containsKey(boardCode) ||
        !adjacency.containsKey(terminalCode)) {
      return const [];
    }
    final path = _bfsPath(adjacency, boardCode, terminalCode);
    if (path.length < 2) return const [];
    return [
      for (final code in path.skip(1))
        MetroPathStop(
          id: code,
          name: stationNames[code] ?? code,
          line: line,
        ),
    ];
  }

  /// Undirected adjacency for one line: the numerically ordered trunk chained
  /// end to end, plus each branch spur wired onto its connect station.
  static Map<String, Set<String>> _adjacency(String line) {
    final branchMembers = <String>{
      for (final branch in _branches[line] ?? const <_Branch>[])
        ...branch.chain,
    };
    final trunk =
        stationNames.keys
            .where((code) => _lineOf(code) == line)
            .where((code) => !branchMembers.contains(code))
            .toList()
          ..sort((a, b) => _numberOf(a).compareTo(_numberOf(b)));

    final graph = <String, Set<String>>{};
    void link(String a, String b) {
      graph.putIfAbsent(a, () => <String>{}).add(b);
      graph.putIfAbsent(b, () => <String>{}).add(a);
    }

    for (var i = 0; i < trunk.length; i++) {
      graph.putIfAbsent(trunk[i], () => <String>{});
      if (i > 0) link(trunk[i - 1], trunk[i]);
    }
    for (final branch in _branches[line] ?? const <_Branch>[]) {
      var prev = branch.connect;
      for (final node in branch.chain) {
        link(prev, node);
        prev = node;
      }
    }
    return graph;
  }

  /// Shortest path from [from] to [to] over [graph]. Metro lines are trees
  /// (no cycles), so the shortest path is the only path.
  static List<String> _bfsPath(
    Map<String, Set<String>> graph,
    String from,
    String to,
  ) {
    final previous = <String, String>{};
    final visited = <String>{from};
    final queue = <String>[from];
    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      if (node == to) break;
      for (final next in graph[node] ?? const <String>{}) {
        if (visited.add(next)) {
          previous[next] = node;
          queue.add(next);
        }
      }
    }
    if (from != to && !previous.containsKey(to)) return const [];
    final path = <String>[to];
    var cursor = to;
    while (cursor != from) {
      cursor = previous[cursor]!;
      path.add(cursor);
    }
    return path.reversed.toList();
  }

  static Map<String, String> _buildNames() {
    final names = <String, String>{};
    for (final station in metroMapStations) {
      for (final code in station.id.split('_')) {
        names[code] = station.name;
      }
    }
    return names;
  }

  /// Leading letters of a code, e.g. `BL12` → `BL`, `G03A` → `G`.
  static String _lineOf(String code) {
    final match = RegExp('^([A-Za-z]+)').firstMatch(code);
    return match?.group(1) ?? code;
  }

  /// The numeric run of a code, used to order the trunk. `R22A` yields 22, but
  /// branch leaves never reach the trunk sort so the trailing letter is moot.
  static int _numberOf(String code) {
    final match = RegExp(r'(\d+)').firstMatch(code);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }
}

class _Branch {
  const _Branch({required this.connect, required this.chain});
  final String connect;
  final List<String> chain;
}
