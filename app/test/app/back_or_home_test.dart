import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';

Widget _app(String initial, Widget Function(BuildContext) back) {
  return MaterialApp.router(
    routerConfig: GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(
          path: '/deep',
          builder: (context, _) => Scaffold(body: back(context)),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('popOrHome lands on home when a cold link has nothing to pop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        '/deep',
        (context) => TextButton(
          onPressed: context.popOrHome,
          child: const Text('back'),
        ),
      ),
    );
    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('popOrHome pops when there is a page underneath', (tester) async {
    await tester.pumpWidget(
      _app(
        '/',
        (context) => TextButton(
          onPressed: context.popOrHome,
          child: const Text('back'),
        ),
      ),
    );
    final context = tester.element(find.text('home'));
    unawaited(GoRouter.of(context).push('/deep'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('back'), findsNothing);
  });

  testWidgets('maybePopOrHome lands on home from the first route', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        '/deep',
        (context) => TextButton(
          onPressed: context.maybePopOrHome,
          child: const Text('back'),
        ),
      ),
    );
    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
