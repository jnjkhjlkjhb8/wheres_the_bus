import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/motion/predictive_back.dart';

Future<Object?> nativeBack(String method, [Object? arguments]) async {
  const channel = SystemChannels.backGesture;
  final result = await TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );
  return result == null ? null : channel.codec.decodeEnvelope(result);
}

Map<String, Object> backEvent(double progress, int edge) {
  final x = edge == 0 ? 1.0 : 799.0;
  return {
    'touchOffset': [x, 200.0 + progress * 100],
    'progress': progress,
    'swipeEdge': edge,
  };
}

Future<void> openDetail(WidgetTester tester, {bool reduced = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.android,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: BigPredictiveBackPageTransitionsBuilder(),
          },
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('detail')),
              ),
            ),
            child: const Text('open detail'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open detail'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('replacing a live animation keeps its preview progress', (
    tester,
  ) async {
    final override = ValueNotifier<Animation<double>?>(null);
    late PageRoute<void> detail;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                detail = MaterialPageRoute<void>(
                  builder: (context) => ValueListenableBuilder(
                    valueListenable: override,
                    builder: (context, animation, _) =>
                        const BigPredictiveBackPageTransitionsBuilder()
                            .buildTransitions(
                              detail,
                              context,
                              animation ?? detail.animation!,
                              detail.secondaryAnimation!,
                              const Scaffold(body: Center(child: Text('swap'))),
                            ),
                  ),
                );
                unawaited(Navigator.of(context).push(detail));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(await nativeBack('startBackGesture', backEvent(0, 0)), isTrue);
    await tester.pump();
    await nativeBack('updateBackGestureProgress', backEvent(0.5, 0));
    await tester.pump();
    final before = tester.getRect(find.text('swap'));
    override.value = ProxyAnimation(detail.animation);
    await tester.pump();
    expect(tester.getRect(find.text('swap')), before);
    await nativeBack('updateBackGestureProgress', backEvent(0.75, 0));
    await tester.pump();
    expect(tester.getRect(find.text('swap')), isNot(before));
    await nativeBack('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('swap'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    override.dispose();
  });
  testWidgets('cancelled edge previews retain the current route', (
    tester,
  ) async {
    await openDetail(tester);
    for (final edge in [0, 1]) {
      expect(await nativeBack('startBackGesture', backEvent(0, edge)), isTrue);
      await tester.pump();
      await nativeBack('updateBackGestureProgress', backEvent(0.5, edge));
      await tester.pump();
      expect(find.text('detail'), findsOneWidget);
      expect(find.byType(ClipRRect), findsWidgets);
      await nativeBack('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('committed edge previews pop exactly one route', (tester) async {
    await openDetail(tester);
    expect(await nativeBack('startBackGesture', backEvent(0, 0)), isTrue);
    await tester.pump();
    await nativeBack('updateBackGestureProgress', backEvent(0.75, 0));
    await tester.pump();
    await nativeBack('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsNothing);
    expect(find.text('open detail'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reduced motion still cancels and hardware buttons skip previews',
    (
      tester,
    ) async {
      await openDetail(tester, reduced: true);
      expect(
        await nativeBack('startBackGesture', {
          'progress': 0.0,
          'swipeEdge': 0,
        }),
        isFalse,
      );
      expect(find.text('detail'), findsOneWidget);
      expect(await nativeBack('startBackGesture', backEvent(0, 1)), isTrue);
      await tester.pump();
      await nativeBack('updateBackGestureProgress', backEvent(0.4, 1));
      await tester.pump();
      await nativeBack('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  group('preview geometry', () {
    // 800x600 view; the touch starts at y=200 and moves 100px per unit of
    // progress, so the vertical drag is 100 * progress.
    const size = Size(800, 600);

    Finder lifted() => find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          ((w.decoration as BoxDecoration).boxShadow?.length ?? 0) == 1,
    );

    double yShift(double progress) {
      final max = size.height / 12 - 8;
      final raw = 100 * progress;
      final eased = Curves.easeOut.transform(
        (raw.abs() / size.height).clamp(0.0, 1.0),
      );
      return (eased * raw.sign * max).clamp(-max, max);
    }

    for (final (edge, progress) in [(0, 0.5), (1, 0.5), (0, 0.9), (1, 0.25)]) {
      testWidgets('edge $edge at ${progress * 100}% leans, shrinks and '
          'casts a shadow', (tester) async {
        await openDetail(tester);
        expect(
          await nativeBack('startBackGesture', backEvent(0, edge)),
          isTrue,
        );
        await tester.pump();
        await nativeBack(
          'updateBackGestureProgress',
          backEvent(progress, edge),
        );
        await tester.pump();

        final scale = 1 - 0.1 * progress;
        // The translation sits inside the scale, so it shrinks with it.
        final xShift =
            (size.width / 12 - 8) * progress * (edge == 0 ? 1 : -1) * scale;
        final rect = tester.getRect(lifted().last);
        expect(rect.width, closeTo(size.width * scale, 0.01));
        expect(rect.height, closeTo(size.height * scale, 0.01));
        expect(rect.center.dx, closeTo(size.width / 2 + xShift, 0.01));
        expect(
          rect.center.dy,
          closeTo(size.height / 2 + yShift(progress) * scale, 0.01),
        );

        final box = tester.widget<DecoratedBox>(lifted().last);
        final decoration = box.decoration as BoxDecoration;
        expect(
          decoration.boxShadow!.single.color,
          const Color.fromRGBO(
            0,
            0,
            0,
            0.18,
          ).withValues(alpha: 0.18 * progress),
        );
        expect(
          decoration.borderRadius,
          BorderRadius.circular(32 * progress),
        );
        await nativeBack('cancelBackGesture');
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('the vertical drag is eased and capped', (tester) async {
      await openDetail(tester);
      expect(await nativeBack('startBackGesture', backEvent(0, 0)), isTrue);
      await tester.pump();
      await nativeBack('updateBackGestureProgress', {
        'touchOffset': [1.0, 1200.0],
        'progress': 0.5,
        'swipeEdge': 0,
      });
      await tester.pump();

      final capped = (size.height / 12 - 8) * 0.95;
      expect(
        tester.getRect(lifted().last).center.dy,
        closeTo(size.height / 2 + capped, 0.01),
      );

      await nativeBack('updateBackGestureProgress', {
        'touchOffset': [1.0, -900.0],
        'progress': 0.5,
        'swipeEdge': 0,
      });
      await tester.pump();
      expect(
        tester.getRect(lifted().last).center.dy,
        closeTo(size.height / 2 - capped, 0.01),
      );
      await nativeBack('cancelBackGesture');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(max(1, 2), 2);
    });
  });
}
