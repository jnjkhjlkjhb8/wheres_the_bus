import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/settings_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

import '../../support/helpers/i18n.dart';
import '../../support/helpers/in_memory_settings_store.dart';

Future<PackageInfo> _packageInfo() async => PackageInfo(
  appName: 'wheres_the_bus',
  packageName: 'tw.gov.bus',
  version: '4.5.6',
  buildNumber: '9',
);

SettingsScreen _screen([SettingsRepository? settings]) => SettingsScreen(
  settings: settings ?? SettingsRepository(store: InMemorySettingsStore()),
  packageInfoLoader: _packageInfo,
  lastSyncedAtOf: () => null,
  refreshConfig: () async => true,
  latestVersionOf: () => '4.5.6',
);

Widget _app(
  Widget child, {
  Locale locale = const Locale('zh'),
  bool reduceMotion = false,
  double topPadding = 0,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      padding: EdgeInsets.only(top: topPadding),
    ),
    child: home!,
  ),
  home: child,
);

SliverPersistentHeaderDelegate _delegate(WidgetTester tester) => tester
    .widget<SliverPersistentHeader>(find.byType(SliverPersistentHeader))
    .delegate;

Future<SliverPersistentHeaderDelegate> _delegateFor(
  WidgetTester tester, {
  Locale locale = const Locale('zh'),
  bool reduceMotion = false,
  double topPadding = 0,
}) async {
  await tester.pumpWidget(
    _app(
      _screen(),
      locale: locale,
      reduceMotion: reduceMotion,
      topPadding: topPadding,
    ),
  );
  await tester.pumpAndSettle();
  return _delegate(tester);
}

Future<void> _pumpHeader(
  WidgetTester tester,
  SliverPersistentHeaderDelegate delegate,
  double offset,
) async {
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: SizedBox(
          width: 400,
          height: delegate.maxExtent,
          child: Builder(
            builder: (context) => delegate.build(context, offset, false),
          ),
        ),
      ),
    ),
  );
}

double _opacityOf(WidgetTester tester, Finder title) => tester
    .widget<Opacity>(
      find.ancestor(of: title, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  group('large title header', () {
    testWidgets('extents stack the 44px bar over the 52px title', (
      tester,
    ) async {
      final delegate = await _delegateFor(tester, topPadding: 20);
      expect(delegate.minExtent, 64);
      expect(delegate.maxExtent, 116);
    });

    testWidgets('at rest only the large title shows, flat and unblurred', (
      tester,
    ) async {
      final delegate = await _delegateFor(tester);
      await _pumpHeader(tester, delegate, 0);
      expect(find.byType(BackdropFilter), findsNothing);
      final titles = find.text('設定');
      expect(titles, findsNWidgets(2));
      expect(_opacityOf(tester, titles.first), 0);
      expect(_opacityOf(tester, titles.last), 1);
      final lift = tester.widget<Transform>(
        find.ancestor(of: titles.last, matching: find.byType(Transform)).first,
      );
      expect(lift.transform.getTranslation().y, 0);
    });

    testWidgets('half collapsed blends the bar in on eased curves', (
      tester,
    ) async {
      final delegate = await _delegateFor(tester);
      await _pumpHeader(tester, delegate, 26);
      const t = 0.5;
      final chrome = AppMotion.easeOut.transform(t);
      final blur = (chrome * 6).round() / 6;
      final compact = AppMotion.easeInOut.transform((t - 0.35) / 0.65);
      final large = 1.0 - AppMotion.easeInOut.transform(t / 0.7);
      final titles = find.text('設定');
      expect(_opacityOf(tester, titles.first), closeTo(compact, 1e-9));
      expect(_opacityOf(tester, titles.last), closeTo(large, 1e-9));

      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(
        filter.filter.toString(),
        ImageFilter.blur(sigmaX: 18 * blur, sigmaY: 18 * blur).toString(),
      );
      final cs = Theme.of(tester.element(titles.first)).colorScheme;
      final bar =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(BackdropFilter),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(bar.color, cs.surface.withValues(alpha: 0.72 * chrome));
      final side = (bar.border! as Border).bottom;
      expect(side.color, cs.outlineVariant.withValues(alpha: chrome));
      expect(side.width, 0.5);

      final lift = tester.widget<Transform>(
        find.ancestor(of: titles.last, matching: find.byType(Transform)).first,
      );
      expect(lift.transform.getTranslation().y, closeTo(t * -6, 1e-9));
    });

    testWidgets('fully collapsed shows only the compact title', (tester) async {
      final delegate = await _delegateFor(tester);
      await _pumpHeader(tester, delegate, 52);
      final titles = find.text('設定');
      expect(_opacityOf(tester, titles.first), 1);
      expect(_opacityOf(tester, titles.last), 0);
      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(
        filter.filter.toString(),
        ImageFilter.blur(sigmaX: 18, sigmaY: 18).toString(),
      );
    });

    testWidgets('both titles sit on their own edges', (tester) async {
      final delegate = await _delegateFor(tester, topPadding: 20);
      await _pumpHeader(tester, delegate, 0);
      Positioned around(Finder text) => tester.widget<Positioned>(
        find.ancestor(of: text, matching: find.byType(Positioned)).first,
      );
      final compact = around(find.text('設定').first);
      expect(compact.left, 44);
      expect(compact.right, 44);
      expect(compact.top, 20);
      expect(compact.height, 44);
      final large = around(find.text('設定').last);
      expect(large.left, 20);
      expect(large.right, 20);
      expect(large.bottom, 10);
    });

    testWidgets('reduced motion keeps the large title from lifting', (
      tester,
    ) async {
      final delegate = await _delegateFor(tester, reduceMotion: true);
      await _pumpHeader(tester, delegate, 26);
      final lift = tester.widget<Transform>(
        find
            .ancestor(
              of: find.text('設定').last,
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(lift.transform.getTranslation().y, 0);
    });

    testWidgets('it rebuilds when any input changes and only then', (
      tester,
    ) async {
      final base = await _delegateFor(tester);
      final same = await _delegateFor(tester);
      expect(same.shouldRebuild(base), isFalse);
      final padded = await _delegateFor(tester, topPadding: 10);
      expect(padded.shouldRebuild(base), isTrue);
      final reduced = await _delegateFor(tester, reduceMotion: true);
      expect(reduced.shouldRebuild(base), isTrue);
      final simplified = await _delegateFor(
        tester,
        locale: const Locale.fromSubtags(
          languageCode: 'zh',
          countryCode: 'CN',
        ),
      );
      expect(
        simplified.shouldRebuild(base),
        (simplified as dynamic).title != (base as dynamic).title,
      );
    });
  });

  group('formatSyncFreshness', () {
    test('never synced', () {
      expect(formatSyncFreshness(zhStrings, null), zhStrings.settingsSyncNever);
    });

    test('today shows just the time', () {
      final now = DateTime.now();
      final time = DateFormat('HH:mm').format(now);
      expect(
        formatSyncFreshness(zhStrings, now),
        zhStrings.settingsSyncToday(time),
      );
    });

    test('an earlier day shows the date and time', () {
      final earlier = DateTime.now().subtract(const Duration(days: 3));
      expect(
        formatSyncFreshness(zhStrings, earlier),
        '${DateFormat('MM/dd').format(earlier)} '
        '${DateFormat('HH:mm').format(earlier)}',
      );
    });
  });

  group('rows', () {
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

    testWidgets('each switch row shows its icon and flips on a label tap', (
      tester,
    ) async {
      final settings = SettingsRepository(store: InMemorySettingsStore());
      await tester.pumpWidget(_app(_screen(settings)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(zhStrings.settingsShakeToReport),
        200,
      );
      for (final icon in [
        Icons.notifications_none_rounded,
        Icons.dashboard_customize_outlined,
        Icons.accessible_rounded,
        Icons.vibration_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget, reason: '$icon');
      }
      expect(settings.shakeToReport, isTrue);
      await tester.tap(find.text(zhStrings.settingsShakeToReport));
      await tester.pumpAndSettle();
      expect(settings.shakeToReport, isFalse);
    });

    testWidgets('the update row has no chevron and buzzes when tapped', (
      tester,
    ) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add('${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_app(_screen()));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text(zhStrings.settingsUpdateCheck),
        matching: find.byType(Pressable),
      );
      await tester.scrollUntilVisible(
        find.text(zhStrings.settingsUpdateCheck),
        200,
      );
      expect(
        find.descendant(
          of: row.first,
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );
      await tester.tap(find.text(zhStrings.settingsUpdateCheck));
      await tester.pumpAndSettle();
      expect(calls, contains('HapticFeedbackType.lightImpact'));
    });
  });
}
