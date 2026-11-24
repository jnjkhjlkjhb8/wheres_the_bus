import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/native_confirm.dart';

const _channel = MethodChannel('me.rabbitsayhello.wheresthebus/native_dialog');

/// Mounts a button that opens the confirmation and records its answer.
Future<List<bool>> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(
            await confirmDestructive(
              context,
              title: 'T',
              message: 'M',
              confirmLabel: 'yes',
              cancelLabel: 'no',
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  return answers;
}

void main() {
  group('iOS', () {
    final calls = <MethodCall>[];
    Object? reply;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return reply;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    for (final (answer, expected) in [
      (true, true),
      (false, false),
      (null, false),
    ]) {
      testWidgets('system alert answering $answer resolves $expected', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        reply = answer;
        final answers = await _mount(tester);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;

        expect(answers, [expected]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(calls.single.method, 'confirm');
        expect(calls.single.arguments, {
          'title': 'T',
          'message': 'M',
          'confirmLabel': 'yes',
          'cancelLabel': 'no',
          'dark': false,
        });
      });
    }

    testWidgets('passes the app appearance, not the device one', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      reply = true;
      await _mount(tester, brightness: Brightness.dark);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      expect((calls.single.arguments as Map)['dark'], isTrue);
    });
  });

  group('other platforms', () {
    testWidgets('Material dialog resolves by the button tapped', (
      tester,
    ) async {
      final answers = await _mount(tester);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('T'), findsOneWidget);
      expect(find.text('M'), findsOneWidget);
      await tester.tap(find.text('no'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('yes'));
      await tester.pumpAndSettle();

      expect(answers, [false, true]);
    });

    testWidgets('dismissing by the barrier counts as no', (tester) async {
      final answers = await _mount(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(answers, [false]);
    });
  });
}
