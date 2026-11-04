import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';

import '../../support/helpers/i18n.dart';

void main() {
  testWidgets('the close glyph sits just under the label opacity', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(Scaffold(body: AlightPickCapsule(onCancel: () {}))),
    );
    final cs = Theme.of(
      tester.element(find.byType(AlightPickCapsule)),
    ).colorScheme;
    final icon = tester.widget<Icon>(find.byIcon(Icons.close_rounded));
    expect(icon.color, cs.surface.withValues(alpha: 0.75));
  });

  testWidgets('the host clears the top edge by 14 unless told otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(
        const Scaffold(
          body: AlightPickCapsuleHost(
            picking: true,
            onCancel: _noop,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(tester.widget<Positioned>(find.byType(Positioned)).top, 14);
  });

  testWidgets('a custom inset moves the capsule', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        const Scaffold(
          body: AlightPickCapsuleHost(
            picking: true,
            topInset: 60,
            onCancel: _noop,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(tester.widget<Positioned>(find.byType(Positioned)).top, 60);
  });
}

void _noop() {}
