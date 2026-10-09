import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_bloc.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';
import 'package:wheres_the_bus/features/settings/settings_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/in_memory_settings_store.dart';

Future<PackageInfo> _packageInfo() async => PackageInfo(
  appName: 'wheres_the_bus',
  packageName: 'tw.gov.bus',
  version: '4.5.6',
  buildNumber: '9',
);

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: child,
);

void main() {
  SettingsRepository repo() =>
      SettingsRepository(store: InMemorySettingsStore());

  Widget buildScreen({
    DateTime? Function()? lastSyncedAtOf,
    Future<bool> Function()? refreshConfig,
    String Function()? latestVersionOf,
  }) => SettingsScreen(
    settings: repo(),
    packageInfoLoader: _packageInfo,
    lastSyncedAtOf: lastSyncedAtOf ?? () => null,
    refreshConfig: refreshConfig ?? () async => true,
    // Matches the running 4.5.6 build, so the row starts with nothing to
    // offer unless a test says otherwise.
    latestVersionOf: latestVersionOf ?? () => '4.5.6',
  );

  testWidgets('shows the real PackageInfo version, not a hardcoded one', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(buildScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('目前版本'), 200);

    expect(find.text('4.5.6'), findsOneWidget);
    expect(find.text('1.0.0'), findsNothing);
  });

  testWidgets('FAQ / report-issue / privacy-policy rows are not tappable', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(buildScreen()));
    await tester.pumpAndSettle();

    for (final label in ['常見問題 FAQ', '回報問題', '隱私權政策']) {
      final finder = find.ancestor(
        of: find.text(label),
        matching: find.byType(GestureDetector),
      );
      // No enabled tap target reaches these rows any more; each is either
      // absent or explicitly disabled (F45).
      for (final element in finder.evaluate()) {
        final widget = element.widget as GestureDetector;
        expect(
          widget.onTap,
          isNull,
          reason: '$label must not have a live tap handler',
        );
      }
    }
  });

  testWidgets('the language row is a live picker showing the current choice', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(buildScreen()));
    await tester.pumpAndSettle();

    // Defaults to following the device, and says so rather than sitting blank.
    expect(find.text('跟隨系統'), findsWidgets);

    final finder = find.ancestor(
      of: find.text('語言'),
      matching: find.byType(GestureDetector),
    );
    expect(
      finder.evaluate().any((e) => (e.widget as GestureDetector).onTap != null),
      isTrue,
      reason: 'the language row must be tappable now that it drives the locale',
    );
  });

  testWidgets('picking a language persists it, so a relaunch keeps it', (
    tester,
  ) async {
    final settings = repo();
    await tester.pumpWidget(
      _wrap(
        SettingsScreen(
          settings: settings,
          packageInfoLoader: _packageInfo,
          lastSyncedAtOf: () => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The bloc is what the picker screen ultimately dispatches to; driving it
    // directly keeps this a test of the write-through, not of go_router.
    final context = tester.element(find.byType(Scaffold).first);
    BlocProvider.of<SettingsBloc>(
      context,
    ).add(const LanguageSelected(Language.en));
    await tester.pumpAndSettle();

    // Written through to the box, not just held in bloc state — the root app
    // reads the repository, so a locale that only lived in the bloc would
    // leave the rest of the UI in the old language.
    expect(settings.languageCode, 'en');
    expect(settings.locale, const Locale('en'));
  });

  testWidgets('an English locale resolves through the en delegate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: buildScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(context), const Locale('en'));
    // Until Crowdin returns English copy, app_en.arb is empty and every key
    // falls back to the zh-TW template — which is the designed behavior, so
    // the assertion is on a key whose value is the same in both locales.
    expect(AppI18n.of(context).languageEn, 'English');
  });

  group('檢查更新 row', () {
    // The row sits near the bottom of a long list; the default 800x600 test
    // surface leaves it scrolled into the tree but outside the viewport, so
    // a tap would miss. A phone-shaped surface puts it in reach.
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
            ..physicalSize = const Size(400, 1600)
            ..devicePixelRatio = 1;
      addTearDown(() {
        view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
    });

    Future<void> tapCheckRow(WidgetTester tester, String label) async {
      final finder = find.text(label);
      await tester.scrollUntilVisible(finder, 200);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('idle until asked, then reports up to date', (tester) async {
      await tester.pumpWidget(_wrap(buildScreen()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('檢查更新'), 200);

      // Nothing is claimed before the rider asks.
      expect(find.text('已是最新版本'), findsNothing);

      await tapCheckRow(tester, '檢查更新');
      expect(find.text('已是最新版本'), findsOneWidget);
    });

    testWidgets('a newer release renames the row to its action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(buildScreen(latestVersionOf: () => '5.0.0')),
      );
      await tester.pumpAndSettle();
      await tapCheckRow(tester, '檢查更新');

      // No allowlisted store URL is configured under test, so the row states
      // the release rather than offering a link it cannot open.
      expect(find.text('有新版本'), findsOneWidget);
      expect(find.text('5.0.0'), findsOneWidget);
      expect(find.text('前往更新'), findsNothing);
    });

    testWidgets('a failed refresh says so instead of claiming current', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          buildScreen(
            refreshConfig: () async => false,
            latestVersionOf: () => '5.0.0',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapCheckRow(tester, '檢查更新');

      expect(find.text('目前無法檢查'), findsOneWidget);
      expect(find.text('已是最新版本'), findsNothing);
    });
  });

  testWidgets('rows reflow under a large text scale without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: buildScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
