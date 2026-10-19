import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/app_dialog.dart';

import '../../support/helpers/i18n.dart';

Future<void> _open(WidgetTester tester, {required bool reduced}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduced);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    i18nApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AppDialog.show<void>(context, title: 'T'),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Finder get _scale => find.ancestor(
  of: find.byType(AppDialog),
  matching: find.byType(ScaleTransition),
);

void main() {
  testWidgets('the dialog grows in from just under full size', (tester) async {
    await _open(tester, reduced: false);
    final scale = tester.widget<ScaleTransition>(_scale).scale.value;
    expect(scale, greaterThan(0.92));
    expect(scale, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.widget<ScaleTransition>(_scale).scale.value, 1);
  });

  testWidgets('reduce motion skips the transition', (tester) async {
    await _open(tester, reduced: true);
    expect(_scale, findsNothing);
    expect(find.text('T'), findsOneWidget);
  });
}
