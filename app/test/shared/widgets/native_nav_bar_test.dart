import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/native_nav_bar.dart';

import '../../support/helpers/fake_uikit.dart';

Widget _app(Widget bar, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: bar),
    );

void main() {
  test('view type matches the one NativeNavBarFactory.swift registers', () {
    expect(
      NativeNavBar.viewType,
      'me.rabbitsayhello.wheresthebus/native_nav_bar',
    );
    expect(NativeNavBar.height, 44);
  });

  // UiKitView only builds on iOS; every test restores the platform before
  // its expectations so a failure cannot leak the override.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('creates the UIKit bar with title and app appearance', (
    tester,
  ) async {
    final uiKit = FakeUiKit(NativeNavBar.viewType);
    await tester.pumpWidget(
      _app(
        const NativeNavBar(title: 'T', subtitle: 'S', trailingWidth: 88),
        brightness: Brightness.dark,
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(NativeNavBar));
    final expected = {
      'title': 'T',
      'subtitle': 'S',
      'backLabel': AppI18n.of(context).commonBack,
      'tint': Theme.of(context).colorScheme.onSurface.toARGB32(),
      'dark': true,
      'trailingWidth': 88.0,
    };
    debugDefaultTargetPlatformOverride = null;

    expect(uiKit.created.single['viewType'], NativeNavBar.viewType);
    expect(uiKit.creationParams(), expected);
    // Re-sent once the channel exists, in case a change raced creation.
    expect(uiKit.updates, [expected]);
  });

  testWidgets('defaults: no subtitle, nothing reserved, light', (tester) async {
    final uiKit = FakeUiKit(NativeNavBar.viewType);
    await tester.pumpWidget(_app(const NativeNavBar(title: 'T')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    final params = uiKit.creationParams();
    expect(params['subtitle'], isNull);
    expect(params['trailingWidth'], 0.0);
    expect(params['dark'], isFalse);
  });

  testWidgets('a change is pushed to the same bar, an equal rebuild is not', (
    tester,
  ) async {
    final uiKit = FakeUiKit(NativeNavBar.viewType);
    await tester.pumpWidget(_app(const NativeNavBar(title: 'A')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(const NativeNavBar(title: 'A')));
    await tester.pumpAndSettle();
    final afterEqualRebuild = uiKit.updates.length;

    await tester.pumpWidget(_app(const NativeNavBar(title: 'B')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _app(const NativeNavBar(title: 'B'), brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    expect(afterEqualRebuild, 1);
    expect(uiKit.created, hasLength(1));
    // The theme change animates, so the tint arrives over several updates.
    expect(uiKit.updates.map((u) => (u['title'], u['dark'])).toSet(), [
      ('A', false),
      ('B', false),
      ('B', true),
    ]);
  });

  testWidgets('native back tap runs onBack, and only that method does', (
    tester,
  ) async {
    final uiKit = FakeUiKit(NativeNavBar.viewType);
    var backs = 0;
    await tester.pumpWidget(
      _app(NativeNavBar(title: 'T', onBack: () => backs++)),
    );
    await tester.pumpAndSettle();

    await uiKit.send(tester, 'other');
    final afterOther = backs;
    await uiKit.send(tester, 'back');
    debugDefaultTargetPlatformOverride = null;

    expect(afterOther, 0);
    expect(backs, 1);
  });

  testWidgets('native back tap pops the route by default, then goes quiet', (
    tester,
  ) async {
    final uiKit = FakeUiKit(NativeNavBar.viewType);
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/detail',
          builder: (_, _) => const Scaffold(body: NativeNavBar(title: 'T')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    final handled = await uiKit.send(tester, 'back');
    final home = find.text('home').evaluate().length;
    // The bar left with its page, so its channel must have no listener.
    final handledAfter = await uiKit.send(tester, 'back');
    debugDefaultTargetPlatformOverride = null;

    expect(handled, isTrue);
    expect(home, 1);
    expect(handledAfter, isFalse);
  });
}
