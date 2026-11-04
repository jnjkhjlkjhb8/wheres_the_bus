import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/shared/motion/predictive_back.dart';

Page<void> _page(String label) =>
    MaterialPage<void>(child: Scaffold(body: Text(label)));

/// The app's shape: results live in the shell branch's navigator, the train
/// page on the root navigator above the whole shell.
GoRouter _router() => GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (_, _, shell) => shell,
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/', pageBuilder: (_, _) => _page('home')),
            GoRoute(path: '/rail', pageBuilder: (_, _) => _page('results')),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/rail/train/:n',
      pageBuilder: (_, _) => _page('train'),
    ),
  ],
);

Future<void> _backGesture(WidgetTester tester) async {
  const codec = StandardMethodCodec();
  Future<void> send(String method, Map<String, Object?> args) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await tester.pump();
  }

  const event = {
    'touchOffset': <double>[2, 300],
    'progress': 0.0,
    'swipeEdge': 0,
  };
  await send('startBackGesture', event);
  await send('updateBackGestureProgress', {...event, 'progress': 0.6});
  await send('commitBackGesture', {});
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a predictive back from a root page leaves the pages below', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: BigPredictiveBackPageTransitionsBuilder(),
            },
          ),
        ),
      ),
    );
    unawaited(router.push('/rail'));
    await tester.pumpAndSettle();
    unawaited(router.push('/rail/train/1'));
    await tester.pumpAndSettle();
    expect(find.text('train'), findsOneWidget);

    await _backGesture(tester);

    expect(find.text('train'), findsNothing);
    expect(find.text('results'), findsOneWidget);
  });
}
