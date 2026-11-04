import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

void main() {
  group('skeleton theme', () {
    test('both themes carry the app-wide skeleton config', () {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        final config = AppTheme.skeleton(
          theme.colorScheme,
          reduceMotion: false,
        );
        final effect = config.resolveEffect(theme.brightness);
        expect(effect, isA<ShimmerEffect>());
        // Bones are the surface the loaded content sits on, swept once per
        // shimmerLoop — a skeleton that outruns the rest of the app's motion
        // reads as a different product.
        expect(effect.duration, AppMotion.shimmerLoop);
      }
    });

    testWidgets('a Skeletonizer paints its child as bones', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: Skeletonizer(child: Text('板橋站')),
          ),
        ),
      );

      // The text still occupies its slot — that is the point of the bone —
      // but it is painted over, so nothing of the placeholder value reads
      // as content.
      expect(find.text('板橋站'), findsOneWidget);
      final scope = tester.widget<SkeletonizerScope>(
        find.byType(SkeletonizerScope),
      );
      expect(scope.enabled, isTrue);
    });
  });
}
