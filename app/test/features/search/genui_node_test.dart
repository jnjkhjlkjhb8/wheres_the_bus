import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';

void main() {
  test('every supported node preserves typed fields and parser defaults', () {
    final nodes = GenUiNode.listFrom([
      {'type': 'heading', 'text': 'Travel options'},
      {'type': 'text', 'text': 'Leave now'},
      {
        'type': 'route',
        'title': 'Route',
        'badges': ['Bus', 42],
        'refUid': '  stop  ',
      },
      {'type': 'step', 'kind': 'walk', 'text': 'Walk there'},
      {'type': 'chip', 'label': 'More', 'query': 'Next', 'refUid': '   '},
      {'type': 'divider'},
      {'type': 'unsupported'},
      42,
    ]);
    expect(nodes, hasLength(6));
    expect((nodes[0] as GenUiHeading).text, 'Travel options');
    expect((nodes[1] as GenUiText).text, 'Leave now');
    final route = nodes[2] as GenUiRoute;
    expect(route.title, 'Route');
    expect(route.badges, ['Bus', '42']);
    expect(route.refUid, 'stop');
    final step = nodes[3] as GenUiStep;
    expect(step.kind, GenUiStepKind.walk);
    expect(step.text, 'Walk there');
    final chip = nodes[4] as GenUiChip;
    expect(chip.label, 'More');
    expect(chip.query, 'Next');
    expect(chip.refUid, isNull);
    expect(nodes[5], isA<GenUiDivider>());
    expect(GenUiNode.listFrom(null), isEmpty);
    expect(GenUiNode.listFrom('invalid'), isEmpty);
    expect(GenUiNode.fromJson({}), isNull);
    expect((GenUiNode.fromJson({'type': 'heading'})! as GenUiHeading).text, '');
    expect((GenUiNode.fromJson({'type': 'text'})! as GenUiText).text, '');
    expect(
      (GenUiNode.fromJson({'type': 'route'})! as GenUiRoute).badges,
      isEmpty,
    );
    expect((GenUiNode.fromJson({'type': 'chip'})! as GenUiChip).query, '');
    expect(
      (GenUiNode.fromJson({'type': 'step'})! as GenUiStep).kind,
      GenUiStepKind.board,
    );
    expect(GenUiStepKind.from('ride'), GenUiStepKind.ride);
    expect(GenUiStepKind.from('alight'), GenUiStepKind.alight);
    expect(GenUiStepKind.from('unknown'), GenUiStepKind.board);
  });

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
