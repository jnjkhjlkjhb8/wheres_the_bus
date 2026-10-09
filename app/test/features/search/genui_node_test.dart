import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';

void main() {
  group('GenUiNode refUid', () {
    test('route parses refUid', () {
      final node = GenUiNode.fromJson({
        'type': 'route',
        'title': '307',
        'badges': <Object?>[],
        'refUid': 'TPE307',
      });
      expect(node, isA<GenUiRoute>());
      expect((node! as GenUiRoute).refUid, 'TPE307');
    });

    test('route without refUid is null', () {
      final node = GenUiNode.fromJson({'type': 'route', 'title': '307'});
      expect((node! as GenUiRoute).refUid, isNull);
    });

    test('route with empty refUid is null', () {
      final node = GenUiNode.fromJson({
        'type': 'route',
        'title': '307',
        'refUid': '',
      });
      expect((node! as GenUiRoute).refUid, isNull);
    });

    test('chip parses refUid', () {
      final node = GenUiNode.fromJson({
        'type': 'chip',
        'label': '台北車站',
        'query': '台北車站',
        'refUid': 'TRA1000',
      });
      expect((node! as GenUiChip).refUid, 'TRA1000');
    });
  });
}
