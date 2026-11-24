import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/core/shortcuts/home_shortcuts.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/i18n.dart';

const _codec = StandardMethodCodec();

void main() {
  late List<MethodCall> sent;
  late Object? pending;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void fakeNative() {
    sent = [];
    pending = null;
    messenger().setMockMethodCallHandler(HomeShortcuts.channel, (call) async {
      sent.add(call);
      return call.method == 'pending' ? pending : null;
    });
    addTearDown(
      () => messenger().setMockMethodCallHandler(HomeShortcuts.channel, null),
    );
  }

  Future<GoRouter> mount(WidgetTester tester, {Locale? locale}) async {
    final router = GoRouter(
      routes: [
        for (final path in ['/', '/search', '/favorites'])
          GoRoute(path: path, builder: (_, _) => Text('at $path')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: locale ?? const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        routerConfig: router,
        builder: (_, child) => HomeShortcuts(router: router, child: child!),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> nativeSends(WidgetTester tester, String method, Object? arg) =>
      messenger().handlePlatformMessage(
        HomeShortcuts.channel.name,
        _codec.encodeMethodCall(MethodCall(method, arg)),
        (_) {},
      );

  testWidgets('publishes search and favorites in the app language', (
    tester,
  ) async {
    fakeNative();
    await mount(tester);
    final sets = [
      for (final c in sent)
        if (c.method == 'set') c.arguments,
    ];

    expect(sets, [
      [
        {'path': '/search', 'title': zhStrings.commonSearch, 'icon': 'search'},
        {
          'path': '/favorites',
          'title': zhStrings.favoritesTitle,
          'icon': 'bookmark',
        },
      ],
    ]);
  });

  testWidgets('republishes when the language changes, not otherwise', (
    tester,
  ) async {
    fakeNative();
    await mount(tester);
    await mount(tester);
    final afterSame = sent.where((c) => c.method == 'set').length;
    await mount(tester, locale: const Locale('en'));
    final titles = [
      for (final c in sent)
        if (c.method == 'set')
          ((c.arguments as List<Object?>).first!
              as Map<Object?, Object?>)['title'],
    ];

    expect(afterSame, 1);
    expect(titles, [zhStrings.commonSearch, 'Search']);
  });

  testWidgets('opens the action that launched the app', (tester) async {
    fakeNative();
    pending = '/favorites';
    await mount(tester);

    expect(find.text('at /favorites'), findsOneWidget);
  });

  testWidgets('opens an action picked while running', (tester) async {
    fakeNative();
    await mount(tester);
    await nativeSends(tester, 'open', '/search');
    await tester.pumpAndSettle();

    expect(find.text('at /search'), findsOneWidget);
  });

  testWidgets('ignores anything but an app path', (tester) async {
    fakeNative();
    await mount(tester);
    for (final bad in ['https://x.test/search', 42, null]) {
      await nativeSends(tester, 'open', bad);
    }
    await nativeSends(tester, 'other', '/search');
    await tester.pumpAndSettle();

    expect(find.text('at /'), findsOneWidget);
  });

  testWidgets('without a native side it stays quiet', (tester) async {
    await mount(tester);

    expect(find.text('at /'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stops listening once removed', (tester) async {
    fakeNative();
    await mount(tester);
    await tester.pumpWidget(const SizedBox());
    var handled = false;
    await messenger().handlePlatformMessage(
      HomeShortcuts.channel.name,
      _codec.encodeMethodCall(const MethodCall('open', '/search')),
      (reply) => handled = reply != null,
    );

    expect(handled, isFalse);
  });
}
